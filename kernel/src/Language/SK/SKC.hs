-- | Wrapper for SK code compilation monad.
{-# LANGUAGE CPP #-}
module Language.SK.SKC
  ( -- * SKC monad
    Skc(..)
  , SkEnv(..)
  , SkEnvRef(..)
  , Macro(..)
  , MacroFunction
  , EnvMacros
  , runSkc
  , debugSkc
  , toGhc
  , fromGhc
  , failS
  , skSrcError
  , emptySkEnv
  , getSkEnv
  , putSkEnv
  , modifySkEnv
  , setDynFlags
  , setContextModules
  , getSkcDebug

  -- * Exception
  , SkException(..)
  , handleSkException

  -- * FlagSet
  , FlagSet
  , emptyFlagSet
  , flagSetToIntList

  -- * Macro related functions
  , emptyEnvMacros
  , insertMacro
  , lookupMacro
  , makeEnvMacros
  , mergeMacros
  , deleteMacro
  , macroNames
  , isMacro
  , macroFunction
  , gensym
  , gensym'
  ) where

-- base
import Control.Exception (Exception(..), throwIO)
import Control.Monad (when)
import Control.Monad.Fail (MonadFail(..))
import Control.Monad.IO.Class (MonadIO(..))
import Data.IORef ( IORef, atomicModifyIORef', newIORef, readIORef
                  , writeIORef )
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)

-- containers
import qualified Data.Map as Map

#if !MIN_VERSION_ghc(8,4,0)
import qualified Data.IntSet as IntSet
#endif

-- ghc
import Bag (unitBag)
import DynFlags ( DynFlags(..), HasDynFlags(..), Language(..)
                , unsafeGlobalDynFlags )
import FastString (FastString, fsLit, unpackFS)
import ErrUtils (mkErrMsg)
import Exception (ExceptionMonad(..), ghandle)
import GHC (runGhc)
import GhcMonad ( Ghc(..), GhcMonad(..), getSessionDynFlags
                , modifySession )
import HsImpExp (simpleImportDecl)
import HscMain (Messager, batchMsg)
import HscTypes ( HomeModInfo, HscEnv(..), InteractiveContext(..)
                , InteractiveImport(..), TyThing(..), mkSrcErr )
import InteractiveEval (setContext)
import Module (ModuleName, mkModuleName)
import Outputable ( alwaysQualify, neverQualify, showSDocForUser, text
                  , ppr )
import SrcLoc (GenLocated(..))
import UniqSupply (mkSplitUniqSupply, uniqFromSupply)
import Var (varType)

#if MIN_VERSION_ghc(8,4,0)
import qualified EnumSet
#endif

-- ghc-boot
#if MIN_VERSION_ghc(8,4,0)
import GHC.LanguageExtensions as LangExt
#endif

-- Internal
import Language.SK.Form


-- ---------------------------------------------------------------------
--
-- Exception
--
-- ---------------------------------------------------------------------

newtype SkException = SkException String
  deriving (Eq, Show)

instance Exception SkException

handleSkException :: ExceptionMonad m
                  => (SkException -> m a) -> m a -> m a
handleSkException = ghandle


-- ---------------------------------------------------------------------
--
-- FlagSet
--
-- ---------------------------------------------------------------------

-- | Type synonym for ghc version compatibility. Used to hold set of
-- language extension bits.
type FlagSet =
#if MIN_VERSION_ghc(8,4,0)
  EnumSet.EnumSet LangExt.Extension
#else
  IntSet.IntSet
#endif

-- | Convert 'FlagSet' to list of 'Int' representation.
flagSetToIntList :: FlagSet -> [Int]
flagSetToIntList =
#if MIN_VERSION_ghc (8,4,0)
  map fromEnum . EnumSet.toList
#else
  IntSet.toList
#endif

-- | Auxiliary function for empty language extension flag set.
emptyFlagSet :: FlagSet
#if MIN_VERSION_ghc(8,4,0)
emptyFlagSet = EnumSet.empty
#else
emptyFlagSet = IntSet.empty
#endif


-- ---------------------------------------------------------------------
--
-- Macro and Skc monad
--
-- ---------------------------------------------------------------------

-- | Macro transformer function.
--
-- A macro in SK is implemented as a function. The function takes a
-- located code data argument, and returns a located code data wrapped
-- in 'Skc'.
type MacroFunction = Code -> Skc Code

-- | Data type to distinguish user defined macros from built-in special
-- forms.
data Macro
  = Macro MacroFunction
  | SpecialForm MacroFunction

instance Show Macro where
  showsPrec _ m =
    case m of
      Macro _      -> showString "<macro>"
      SpecialForm _-> showString "<special-form>"

-- | Type synonym to express mapping of macro name to 'Macro' data.
type EnvMacros = Map.Map FastString Macro

-- | Environment state in 'Skc'.
data SkEnv = SkEnv
   { -- | Macros accessible in current compilation context.
     envMacros :: EnvMacros
     -- | Temporary macros in current compilation context.
   , envTmpMacros :: [EnvMacros]
     -- | Default set of macros, these macros will be used when
     -- resetting 'SkEnv'.
   , envDefaultMacros :: EnvMacros
     -- | Flag to hold debug setting.
   , envDebug :: Bool
     -- | Modules to import to context.
   , envContextModules :: [String]
     -- | Default values to reset the language extensions.
   , envDefaultLangExts :: (Maybe Language, FlagSet)
     -- | Flag for controling informative output.
   , envSilent :: Bool

     -- | Function to compile required modules, when
     -- necessary. Arguments are force recompilation flag and module
     -- name. Returned values are list of pair of name and info of the
     -- compiled home module.
   , envMake :: Maybe (Bool -> String -> Skc [(ModuleName, HomeModInfo)])
     -- | 'DynFlags' used by function in 'envMake' field.
   , envMakeDynFlags :: Maybe DynFlags
     -- | Messager used in make.
   , envMessager :: Messager
     -- | Required modules names in current target.
   , envRequiredModuleNames :: [String]
     -- | Compile home modules during macro-expansion of /require/.
   , envCompiledInRequire :: [(ModuleName, HomeModInfo)]

     -- | Whether to dump Haskell source code or not.
   , envDumpHs :: Bool
     -- | Directory to save generated Haskell source codes.
   , envHsDir :: Maybe FilePath

     -- | Lib directory passed to 'runGhc'.
   , envLibDir :: Maybe FilePath

     -- | Whether to use qualified name for primitive functions used in
     -- quoting codes.
   , envQualifyQuotePrimitives :: Bool
   }

-- | Newtype wrapper for compiling SK code to Haskell AST.
newtype Skc a = Skc {unSkc :: SkEnvRef -> Ghc a}

-- | Reference to 'SkEnv'.
data SkEnvRef = SkEnvRef !(IORef SkEnv)

instance Functor Skc where
  fmap f (Skc m) = Skc (fmap f . m)
  {-# INLINE fmap #-}

instance Applicative Skc where
  pure x = Skc (\_ -> pure x)
  {-# INLINE pure #-}
  Skc f <*> Skc m = Skc (\ref -> f ref <*> m ref)
  {-# INLINE (<*>) #-}

instance Monad Skc where
  return x = Skc (\_ -> return x)
  {-# INLINE return #-}
  Skc m >>= k = Skc (\ref -> m ref >>= \v -> unSkc (k v) ref)
  {-# INLINE (>>=) #-}

instance MonadFail Skc where
  fail = failS
  {-# INLINE fail #-}

instance MonadIO Skc where
  liftIO io = Skc (\_ -> liftIO io)
  {-# INLINE liftIO #-}

instance ExceptionMonad Skc where
  gcatch m h =
    Skc (\ref -> unSkc m ref `gcatch` \e -> unSkc (h e) ref)
  {-# INLINE gcatch #-}
  gmask f =
    Skc (\ref ->
           gmask (\r -> let r' m = Skc (\ref' -> r (unSkc m ref'))
                        in  unSkc (f r') ref))
  {-# INLINE gmask #-}

instance HasDynFlags Skc where
  getDynFlags = Skc (\_ -> getDynFlags)
  {-# INLINE getDynFlags #-}

instance GhcMonad Skc where
  getSession = Skc (\_ -> getSession)
  {-# INLINE getSession #-}
  setSession hsc_env = Skc (\_ -> setSession hsc_env)
  {-# INLINE setSession #-}

-- | Run 'Skc' with given environment.
runSkc :: Skc a -> SkEnv -> IO a
runSkc m sk_env = do
  ref <- newIORef sk_env
  runGhc (envLibDir sk_env) (toGhc m (SkEnvRef ref))

-- | Extract 'Ghc' from 'Skc'.
toGhc :: Skc a -> SkEnvRef -> Ghc a
toGhc = unSkc
{-# INLINE toGhc #-}

-- | Lift 'Ghc' to 'Skc'.
fromGhc :: Ghc a -> Skc a
fromGhc m = Skc (\_ -> m)
{-# INLINE fromGhc #-}

-- | Get current 'SkEnv'.
getSkEnv :: Skc SkEnv
getSkEnv = Skc (\(SkEnvRef ref) -> liftIO (readIORef ref))
{-# INLINE getSkEnv #-}

-- | Set current 'SkEnv' to given argument.
putSkEnv :: SkEnv -> Skc ()
putSkEnv sk_env =
  Skc (\(SkEnvRef ref) -> sk_env `seq` liftIO (writeIORef ref sk_env))
{-# INLINE putSkEnv #-}

-- | Update 'SkEnv' with applying given function to current 'SkEnv'.
modifySkEnv :: (SkEnv -> SkEnv) -> Skc ()
modifySkEnv f =
  Skc (\(SkEnvRef ref) ->
         liftIO (atomicModifyIORef' ref (\sk_env -> (f sk_env, ()))))
{-# INLINE modifySkEnv #-}

-- | Throw 'SkException' with given message.
failS :: String -> Skc a
failS msg = liftIO (throwIO (SkException msg))

-- | Throw a 'SourceError'.
skSrcError :: Code -> String -> Skc a
skSrcError (LForm (L l _)) msg = do
  dflags <- getSessionDynFlags
  let em = mkErrMsg dflags l neverQualify (text msg)
  liftIO (throwIO (mkSrcErr (unitBag em)))

-- | Perform given IO action iff debug flag is turned on.
debugSkc :: String -> Skc ()
debugSkc str = do
  sk_env <- getSkEnv
  when (envDebug sk_env)
       (liftIO (hPutStrLn stderr str))
{-# INLINE debugSkc #-}

-- | Empty 'SkEnv' for performing computation with 'Skc'.
emptySkEnv :: SkEnv
emptySkEnv = SkEnv
  { envMacros                 = emptyEnvMacros
  , envTmpMacros              = []
  , envDefaultMacros          = emptyEnvMacros
  , envDebug                  = False
  , envContextModules         = []
  , envDefaultLangExts        = (Nothing, emptyFlagSet)
  , envSilent                 = False
  , envMake                   = Nothing
  , envMakeDynFlags           = Nothing
  , envMessager               = batchMsg
  , envRequiredModuleNames    = []
  , envCompiledInRequire      = []
  , envDumpHs                 = False
  , envHsDir                  = Nothing
  , envLibDir                 = Nothing
  , envQualifyQuotePrimitives = False }

-- | Set current 'DynFlags' to given argument. This function also
-- modifies 'DynFlags' in interactive context.
setDynFlags :: DynFlags -> Skc ()
setDynFlags dflags =
  fromGhc (modifySession
            (\h -> h { hsc_dflags = dflags
                     , hsc_IC = (hsc_IC h) {ic_dflags = dflags}}))
{-# INLINE setDynFlags #-}

-- | Set context modules in current session to given modules.
setContextModules :: [String] -> Skc ()
setContextModules names = do
  let ii = IIDecl . simpleImportDecl . mkModuleName
  setContext (map ii names)

-- | Get sk debug setting from environment variable /SKC_DEBUG/.
getSkcDebug :: MonadIO m => m Bool
getSkcDebug =
  do mb_debug <- liftIO (lookupEnv "SKC_DEBUG")
     case mb_debug of
       Nothing -> return False
       Just _  -> return True
{-# INLINE getSkcDebug #-}

-- | Insert new macro. This function will override existing macro.
insertMacro :: FastString -> Macro -> Skc ()
insertMacro k v =
  modifySkEnv (\e -> e {envMacros = Map.insert k v (envMacros e)})

-- | Lookup macro by name.
--
-- Lookup macro from persistent and temporary macros. When macros with
-- conflicting name exist, the latest temporary macro wins.
lookupMacro :: FastString -> SkEnv -> Maybe Macro
lookupMacro name ske = go (envTmpMacros ske)
  where
    go [] = Map.lookup name (envMacros ske)
    go (t:ts)
      | Just macro <- Map.lookup name t = Just macro
      | otherwise = go ts

-- | Empty 'EnvMacros'.
emptyEnvMacros :: EnvMacros
emptyEnvMacros = Map.empty

-- | Make 'EnvMacros' from list of pair of macro name and value.
makeEnvMacros :: [(String, Macro)] -> EnvMacros
makeEnvMacros = Map.fromList . map (\(n,m) -> (fsLit n, m))

-- | Merge macros.
mergeMacros :: EnvMacros -> EnvMacros -> EnvMacros
mergeMacros = Map.union

-- | Delete macro by macro name.
deleteMacro :: FastString -> EnvMacros -> EnvMacros
deleteMacro = Map.delete

-- | All macros in given macro environment, filtering out the special
-- forms.
macroNames :: EnvMacros -> [String]
macroNames = Map.foldrWithKey f []
  where
    f k m acc = case m of
                  Macro _ -> unpackFS k : acc
                  _       -> acc

-- | 'True' when given 'TyThing' is a 'Macro'.
isMacro :: TyThing -> Bool
isMacro thing =
  case thing of
    AnId var -> showSDocForUser unsafeGlobalDynFlags alwaysQualify
                                (ppr (varType var))
                == "Language.SK.SKC.Macro"
    _        -> False

-- | Extract function from macro and apply to given code. Uses
-- 'emptySkEnv' with 'specialForms' to unwrap the macro from 'Skc'.
macroFunction :: Macro -> Code -> Skc Code
macroFunction mac form =
  let fn = case mac of
             Macro f       -> f
             SpecialForm f -> f
  in  fn form

-- | Generate unique symbol with @gensym'@.
gensym :: Skc Code
gensym = gensym' "g"

-- | Generate unique symbol with given prefix.
--
-- Note that although this function does not generate same symbol twice,
-- generated symbols have a chance to have same name from symbols
-- entered from codes written by arbitrary users.
gensym' :: String -> Skc Code
gensym' prefix = do
  s <- liftIO (mkSplitUniqSupply '_')
  let u = uniqFromSupply s
  return (LForm (genSrc (Atom (aSymbol (prefix ++ show u)))))
