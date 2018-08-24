-- | Wrapper for SK code compilation monad.

module Language.SK.SKC
  ( Skc(..)
  , SkEnv(..)
  , SkException(..)
  , Macro(..)
  , EnvMacros
  , handleSkException
  , debugIO
  , toGhc
  , fromGhc
  , failS
  , skSrcError
  , getSkEnv
  , putSkEnv
  , modifySkEnv
  , setDynFlags
  , insertMacro
  , lookupMacro
  , makeEnvMacros
  , mergeMacros
  , deleteMacro
  , macroNames
  , isMacro
  , gensym
  , gensym'
  ) where

-- base
import Control.Exception (Exception(..), throwIO)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO(..))

-- containers
import qualified Data.IntSet as IntSet
import qualified Data.Map as Map

-- ghc
import Bag (unitBag)
import DynFlags ( DynFlags(..), HasDynFlags(..), Language(..)
                , unsafeGlobalDynFlags )
import FastString (FastString, unpackFS)
import ErrUtils (mkErrMsg)
import Exception (ExceptionMonad(..), ghandle)
import GhcMonad ( Ghc(..), GhcMonad(..), getSessionDynFlags
                , modifySession )
import HscTypes ( HscEnv(..), InteractiveContext(..), TyThing(..)
                , mkSrcErr )
import Outputable ( alwaysQualify, neverQualify, showSDocForUser, text
                  , ppr )
import UniqSupply (mkSplitUniqSupply, uniqFromSupply)
import Var (varType)

-- transformers
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State.Strict (StateT(..), get, modify, put)

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
-- Macro and Skc monad
--
-- ---------------------------------------------------------------------

-- | Macro transformer function.
--
-- A macro in SK is implemented as a function. The function takes a
-- single located code data argument, returns a located code data
-- wrapped in 'Skc'.
data Macro
  = Macro (Code -> Skc Code)
  | SpecialForm (Code -> Skc Code)

instance Show Macro where
  showsPrec _ m =
    case m of
      Macro _      -> showString "<macro>"
      SpecialForm _-> showString "<special-form>"

type EnvMacros = Map.Map FastString Macro

-- | Environment state in 'Skc'.
data SkEnv = SkEnv
   { -- | Macros accessible in current compilation context.
     envMacros :: EnvMacros
     -- | Temporary macros in current compilation context.
   , envTmpMacros :: [EnvMacros]
     -- | Default set of macros to reset the macros.
   , envDefaultMacros :: EnvMacros
     -- | Flag to hold debug setting.
   , envDebug :: Bool
     -- | Modules to import to context.
   , envContextModules :: [String]
     -- | Default values to reset the language extensions.
   , envDefaultLangExts :: (Maybe Language, IntSet.IntSet)
     -- | Flag for controling informative output.
   , envSilent :: Bool
     -- | Flag for adding macros with @define-macro@.
   , envAddInDefineMacro :: Bool
   }

-- | Newtype wrapper for compiling SK code to Haskell AST.
newtype Skc a = Skc {
  unSkc :: StateT SkEnv Ghc a
}

instance Functor Skc where
  fmap f (Skc m) = Skc (fmap f m)
  {-# INLINE fmap #-}

instance Applicative Skc where
  pure = Skc . pure
  {-# INLINE pure #-}
  Skc m <*> Skc f = Skc (m <*> f)
  {-# INLINE (<*>) #-}

instance Monad Skc where
  return = Skc . return
  {-# INLINE return #-}
  Skc m >>= k = Skc (m >>= unSkc . k)
  {-# INLINE (>>=) #-}

instance MonadIO Skc where
  liftIO = Skc . liftIO
  {-# INLINE liftIO #-}

instance ExceptionMonad Skc where
  gcatch m h =
    Skc (StateT (\st ->
                   (toGhc m st `gcatch` \e -> toGhc (h e) st)))
  gmask f =
    let g r m = Skc (StateT (r . toGhc m))
    in  Skc (StateT (\st ->
                       (gmask (\r -> toGhc (f (g r)) st))))

instance HasDynFlags Skc where
   getDynFlags = Skc (lift getDynFlags)
   {-# INLINE getDynFlags #-}

instance GhcMonad Skc where
   getSession = Skc (lift getSession)
   {-# INLINE getSession #-}
   setSession = Skc . lift . setSession
   {-# INLINE setSession #-}

toGhc :: Skc a -> SkEnv -> Ghc (a, SkEnv)
toGhc m = runStateT (unSkc m)
{-# INLINE toGhc #-}

fromGhc :: Ghc a -> Skc a
fromGhc m = Skc (lift m)
{-# INLINE fromGhc #-}

failS :: String -> Skc a
failS msg = liftIO (throwIO (SkException msg))

-- | Throw a 'SourceError'.
skSrcError :: Code -> String -> Skc a
skSrcError (LForm (L l _)) msg = do
  dflags <- getSessionDynFlags
  let em = mkErrMsg dflags l neverQualify (text msg)
  liftIO (throwIO (mkSrcErr (unitBag em)))

-- | Perform given IO action iff debug flag is turned on.
debugIO :: IO () -> Skc ()
debugIO act = Skc go
  where
    go = do
      sk_env <- get
      when (envDebug sk_env)
           (liftIO act)

getSkEnv :: Skc SkEnv
getSkEnv = Skc get
{-# INLINE getSkEnv #-}

putSkEnv :: SkEnv -> Skc ()
putSkEnv = Skc . put
{-# INLINE putSkEnv #-}

modifySkEnv :: (SkEnv -> SkEnv) -> Skc ()
modifySkEnv f = Skc (get >>= put . f)
{-# INLINE modifySkEnv #-}

setDynFlags :: DynFlags -> Skc ()
setDynFlags dflags =
  fromGhc (modifySession
            (\h -> h { hsc_dflags = dflags
                     , hsc_IC = (hsc_IC h) {ic_dflags = dflags}}))
{-# INLINE setDynFlags #-}

-- | Insert new macro. This function will override existing macro.
insertMacro :: FastString -> Macro -> Skc ()
insertMacro k v = Skc go
  where
    go = modify (\e -> e {envMacros = Map.insert k v (envMacros e)})

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
