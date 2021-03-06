-- | Wrapper for Finkel code compilation monad.
{-# LANGUAGE CPP #-}
module Language.Finkel.Fnk
  ( -- * Finkel compiler monad
    Fnk(..)
  , FnkEnv(..)
  , FnkEnvRef(..)
  , Macro(..)
  , MacroFunction
  , MakeFunction
  , EnvMacros
  , runFnk
  , debugFnk
  , toGhc
  , fromGhc
  , failS
  , finkelSrcError
  , emptyFnkEnv
  , getFnkEnv
  , putFnkEnv
  , modifyFnkEnv
  , setDynFlags
  , setContextModules
  , getFnkDebug

  -- * Exception
  , FinkelException(..)
  , handleFinkelException

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
import           Control.Exception      (Exception (..), throwIO)
import           Control.Monad          (when)

#if !MIN_VERSION_ghc(8,8,0)
import           Control.Monad.Fail     (MonadFail (..))
#endif

import           Control.Monad.IO.Class (MonadIO (..))
import           Data.IORef             (IORef, atomicModifyIORef',
                                         newIORef, readIORef, writeIORef)
import           System.Environment     (lookupEnv)
import           System.IO              (hPutStrLn, stderr)

-- containers
import qualified Data.Map               as Map

-- ghc
import           Bag                    (unitBag)
import           DynFlags               (DynFlags (..), HasDynFlags (..),
                                         Language (..),
                                         unsafeGlobalDynFlags)
import           ErrUtils               (mkErrMsg)
import           Exception              (ExceptionMonad (..), ghandle)
import           FastString             (FastString, fsLit, unpackFS)
import           GHC                    (runGhc)
import           GhcMonad               (Ghc (..), GhcMonad (..),
                                         getSessionDynFlags, modifySession)
import           HscMain                (Messager, batchMsg)
import           HscTypes               (HomeModInfo, HscEnv (..),
                                         InteractiveContext (..),
                                         InteractiveImport (..),
                                         TyThing (..), mkSrcErr)
import           HsImpExp               (simpleImportDecl)
import           InteractiveEval        (setContext)
import           Module                 (ModuleName, mkModuleName)
import           Outputable             (alwaysQualify, neverQualify, ppr,
                                         showSDocForUser, text)
import           SrcLoc                 (GenLocated (..), Located)
import           UniqSupply             (mkSplitUniqSupply, uniqFromSupply)
import           Var                    (varType)

-- Import for FlagSet
#if MIN_VERSION_ghc(8,4,0)
-- ghc
import qualified EnumSet
-- ghc-boot
import           GHC.LanguageExtensions as LangExt
#else
-- containers
import qualified Data.IntSet            as IntSet
#endif

-- Internal
import           Language.Finkel.Form


-- ---------------------------------------------------------------------
--
-- Exception
--
-- ---------------------------------------------------------------------

newtype FinkelException = FinkelException String
  deriving (Eq, Show)

instance Exception FinkelException

handleFinkelException :: ExceptionMonad m
                  => (FinkelException -> m a) -> m a -> m a
handleFinkelException = ghandle


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
#if MIN_VERSION_ghc(8,4,0)
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
-- Macro and Fnk monad
--
-- ---------------------------------------------------------------------

-- | Macro transformer function.
--
-- A macro in Finkel is implemented as a function. The function takes
-- a located code data argument, and returns a located code data
-- wrapped in 'Fnk'.
type MacroFunction = Code -> Fnk Code

-- | Data type to distinguish user defined macros from built-in special
-- forms.
data Macro
  = Macro MacroFunction
  | SpecialForm MacroFunction

instance Show Macro where
  showsPrec _ m =
    case m of
      Macro _       -> showString "<macro>"
      SpecialForm _ -> showString "<special-form>"

-- | Type synonym to express mapping of macro name to 'Macro' data.
type EnvMacros = Map.Map FastString Macro

-- | Type synonym for the function to recursively compile modules during
-- @require@.
type MakeFunction =
  Bool -> Located String -> Fnk [(ModuleName, HomeModInfo)]

-- | Environment state in 'Fnk'.
data FnkEnv = FnkEnv
   { -- | Macros accessible in current compilation context.
     envMacros                 :: EnvMacros
     -- | Temporary macros in current compilation context.
   , envTmpMacros              :: [EnvMacros]
     -- | Default set of macros, these macros will be used when
     -- resetting 'FnkEnv'.
   , envDefaultMacros          :: EnvMacros
     -- | Flag to hold debug setting.
   , envDebug                  :: Bool
     -- | Modules to import to context.
   , envContextModules         :: [String]
     -- | Default values to reset the language extensions.
   , envDefaultLangExts        :: (Maybe Language, FlagSet)
     -- | Flag for controling informative output.
   , envSilent                 :: Bool

     -- | Function to compile required modules, when
     -- necessary. Arguments are force recompilation flag and module
     -- name. Returned values are list of pair of name and info of the
     -- compiled home module.
   , envMake                   :: Maybe MakeFunction
     -- | 'DynFlags' used by function in 'envMake' field.
   , envMakeDynFlags           :: Maybe DynFlags
     -- | Messager used in make.
   , envMessager               :: Messager
     -- | Required modules names in current target.
   , envRequiredModuleNames    :: [Located String]
     -- | Compile home modules during macro-expansion of /require/.
   , envCompiledInRequire      :: [(ModuleName, HomeModInfo)]

     -- | Whether to dump Haskell source code or not.
   , envDumpHs                 :: Bool
     -- | Directory to save generated Haskell source codes.
   , envHsDir                  :: Maybe FilePath

     -- | Lib directory passed to 'runGhc'.
   , envLibDir                 :: Maybe FilePath

     -- | Whether to use qualified name for primitive functions used in
     -- quoting codes.
   , envQualifyQuotePrimitives :: Bool
   }

-- | Newtype wrapper for compiling Finkel code to Haskell AST.
newtype Fnk a = Fnk {unFnk :: FnkEnvRef -> Ghc a}

-- | Reference to 'FnkEnv'.
data FnkEnvRef = FnkEnvRef !(IORef FnkEnv)

instance Functor Fnk where
  fmap f (Fnk m) = Fnk (fmap f . m)
  {-# INLINE fmap #-}

instance Applicative Fnk where
  pure x = Fnk (\_ -> pure x)
  {-# INLINE pure #-}
  Fnk f <*> Fnk m = Fnk (\ref -> f ref <*> m ref)
  {-# INLINE (<*>) #-}

instance Monad Fnk where
  return x = Fnk (\_ -> return x)
  {-# INLINE return #-}
  Fnk m >>= k = Fnk (\ref -> m ref >>= \v -> unFnk (k v) ref)
  {-# INLINE (>>=) #-}

instance MonadFail Fnk where
  fail = failS
  {-# INLINE fail #-}

instance MonadIO Fnk where
  liftIO io = Fnk (\_ -> liftIO io)
  {-# INLINE liftIO #-}

instance ExceptionMonad Fnk where
  gcatch m h =
    Fnk (\ref -> unFnk m ref `gcatch` \e -> unFnk (h e) ref)
  {-# INLINE gcatch #-}
  gmask f =
    Fnk (\ref ->
           gmask (\r -> let r' m = Fnk (\ref' -> r (unFnk m ref'))
                        in  unFnk (f r') ref))
  {-# INLINE gmask #-}

instance HasDynFlags Fnk where
  getDynFlags = Fnk (\_ -> getDynFlags)
  {-# INLINE getDynFlags #-}

instance GhcMonad Fnk where
  getSession = Fnk (\_ -> getSession)
  {-# INLINE getSession #-}
  setSession hsc_env = Fnk (\_ -> setSession hsc_env)
  {-# INLINE setSession #-}

-- | Run 'Fnk' with given environment.
runFnk :: Fnk a -> FnkEnv -> IO a
runFnk m fnkc_env = do
  ref <- newIORef fnkc_env
  runGhc (envLibDir fnkc_env) (toGhc m (FnkEnvRef ref))

-- | Extract 'Ghc' from 'Fnk'.
toGhc :: Fnk a -> FnkEnvRef -> Ghc a
toGhc = unFnk
{-# INLINE toGhc #-}

-- | Lift 'Ghc' to 'Fnk'.
fromGhc :: Ghc a -> Fnk a
fromGhc m = Fnk (\_ -> m)
{-# INLINE fromGhc #-}

-- | Get current 'FnkEnv'.
getFnkEnv :: Fnk FnkEnv
getFnkEnv = Fnk (\(FnkEnvRef ref) -> liftIO (readIORef ref))
{-# INLINE getFnkEnv #-}

-- | Set current 'FnkEnv' to given argument.
putFnkEnv :: FnkEnv -> Fnk ()
putFnkEnv fnkc_env =
  Fnk (\(FnkEnvRef ref) -> fnkc_env `seq` liftIO (writeIORef ref fnkc_env))
{-# INLINE putFnkEnv #-}

-- | Update 'FnkEnv' with applying given function to current 'FnkEnv'.
modifyFnkEnv :: (FnkEnv -> FnkEnv) -> Fnk ()
modifyFnkEnv f =
  Fnk (\(FnkEnvRef ref) ->
         liftIO (atomicModifyIORef' ref (\fnkc_env -> (f fnkc_env, ()))))
{-# INLINE modifyFnkEnv #-}

-- | Throw 'FinkelException' with given message.
failS :: String -> Fnk a
failS msg = liftIO (throwIO (FinkelException msg))

-- | Throw a 'SourceError'.
finkelSrcError :: Code -> String -> Fnk a
finkelSrcError (LForm (L l _)) msg = do
  dflags <- getSessionDynFlags
  let em = mkErrMsg dflags l neverQualify (text msg)
  liftIO (throwIO (mkSrcErr (unitBag em)))

-- | Perform given IO action iff debug flag is turned on.
debugFnk :: String -> Fnk ()
debugFnk str = do
  fnkc_env <- getFnkEnv
  when (envDebug fnkc_env)
       (liftIO (hPutStrLn stderr str))
{-# INLINE debugFnk #-}

-- | Empty 'FnkEnv' for performing computation with 'Fnk'.
emptyFnkEnv :: FnkEnv
emptyFnkEnv = FnkEnv
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
setDynFlags :: DynFlags -> Fnk ()
setDynFlags dflags =
  fromGhc (modifySession
            (\h -> h { hsc_dflags = dflags
                     , hsc_IC = (hsc_IC h) {ic_dflags = dflags}}))
{-# INLINE setDynFlags #-}

-- | Set context modules in current session to given modules.
setContextModules :: [String] -> Fnk ()
setContextModules names = do
  let ii = IIDecl . simpleImportDecl . mkModuleName
  setContext (map ii names)

-- | Get finkel debug setting from environment variable /FNKC_DEBUG/.
getFnkDebug :: MonadIO m => m Bool
getFnkDebug =
  do mb_debug <- liftIO (lookupEnv "FNKC_DEBUG")
     case mb_debug of
       Nothing -> return False
       Just _  -> return True
{-# INLINE getFnkDebug #-}

-- | Insert new macro. This function will override existing macro.
insertMacro :: FastString -> Macro -> Fnk ()
insertMacro k v =
  modifyFnkEnv (\e -> e {envMacros = Map.insert k v (envMacros e)})

-- | Lookup macro by name.
--
-- Lookup macro from persistent and temporary macros. When macros with
-- conflicting name exist, the latest temporary macro wins.
lookupMacro :: FastString -> FnkEnv -> Maybe Macro
lookupMacro name fnkc_env = go (envTmpMacros fnkc_env)
  where
    go [] = Map.lookup name (envMacros fnkc_env)
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
                == "Language.Finkel.Fnk.Macro"
    _        -> False

-- | Extract function from macro and apply to given code. Uses
-- 'emptyFnkEnv' with 'specialForms' to unwrap the macro from 'Fnk'.
macroFunction :: Macro -> Code -> Fnk Code
macroFunction mac form =
  let fn = case mac of
             Macro f       -> f
             SpecialForm f -> f
  in  fn form

-- | Generate unique symbol with @gensym'@.
gensym :: Fnk Code
gensym = gensym' "g"

-- | Generate unique symbol with given prefix.
--
-- Note that although this function does not generate same symbol twice,
-- generated symbols have a chance to have same name from symbols
-- entered from codes written by arbitrary users.
gensym' :: String -> Fnk Code
gensym' prefix = do
  s <- liftIO (mkSplitUniqSupply '_')
  let u = uniqFromSupply s
  return (LForm (genSrc (Atom (aSymbol (prefix ++ show u)))))
