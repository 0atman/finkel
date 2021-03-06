-- | Module exporting utilities to work with cabal's @Setup.hs@ script.
{-# LANGUAGE CPP #-}
module Distribution.Simple.Finkel
  (
  -- * Main functions
    fnkMain
  , fnkInternalMain
  , fnkMainWith
  , makeFnkMain

  -- * UserHooks
  , fnkHooksWith

   -- * Reexport from Cabal
  , UserHooks
  , defaultMainWithHooks
  ) where

-- base
import           Control.Exception                  (bracket_)
import           Control.Monad                      (foldM, mapAndUnzipM,
                                                     when)
import           Data.Foldable                      (toList)
import           Data.Function                      (on)
import           Data.List                          (isSubsequenceOf,
                                                     unionBy)

#if !MIN_VERSION_base(4,13,0)
import           Data.Monoid                        (Monoid (..))
#endif

import           System.Environment                 (getExecutablePath)

-- filepath
import           System.FilePath                    ((<.>), (</>))

-- Cabal
import           Distribution.ModuleName            (toFilePath)
import           Distribution.PackageDescription
import           Distribution.Simple
import           Distribution.Simple.BuildPaths     (autogenComponentModulesDir)
import           Distribution.Simple.Configure      (configure,
                                                     findDistPrefOrDefault)
import           Distribution.Simple.Haddock        (haddock)
import           Distribution.Simple.LocalBuildInfo
import           Distribution.Simple.PreProcess
import           Distribution.Simple.Program
import           Distribution.Simple.Program.GHC
import           Distribution.Simple.Program.Types
import           Distribution.Simple.Register       (internalPackageDBPath)
import           Distribution.Simple.Setup
import           Distribution.Utils.NubList

#if MIN_VERSION_Cabal(2,4,0)
import           Distribution.Types.ExposedModule
#else
import           Distribution.InstalledPackageInfo
#endif

-- directory
import           System.Directory                   (doesFileExist,
                                                     findFile, removeFile)

import qualified Distribution.Simple.Setup          as Setup
import qualified Distribution.Verbosity             as Verbosity


-- --------------------------------------------------------------------
--
-- Main functions
--
-- ------------------------------------------------------------------------

-- | Main function using /fnkc/ executable.
--
-- This acton uses the /fnkc/ executable found on system when building
-- a package with /stack/, and wrap with /cabal v2-exec/ when
-- buildiing with /cabal-install/.
fnkMain :: IO ()
fnkMain = fnkMainWith "fnkc" []

-- | Main function using /fnkc/ executable for finkel-XXX packages.
--
-- This function is intended to be used via @stack@ and
-- @cabal@. It calls given executable via @cabal new-run@ when the
-- executable built from @Setup.hs@ were not for @stack@.
fnkInternalMain :: IO ()
fnkInternalMain = makeFnkMain "v2-run" "fnkc" []

-- | Main function with given executable name and arguments passed to
-- the executable.
fnkMainWith :: String   -- ^ Executable name.
            -> [String] -- ^ Args passed to the executable.
            -> IO ()
fnkMainWith = makeFnkMain "v2-exec"

-- | Make a main function for compiling Finkel codes.
makeFnkMain :: String   -- ^ Cabal command to invoke when building
                        -- package with /cabal-install/.
            -> String   -- ^ Executable name.
            -> [String] -- ^ Argument passed to the executable.
            -> IO ()
makeFnkMain cabal_cmd exec args = actWithStackOrCabal stack cabal
  where
    -- Stack change the PATH environment variable, no need to wrap the
    -- executable "stack run".
    stack = defaultMainWithHooks (fnkHooksWith exec args False)

    -- Cabal v2 style build does not change the PATH environment
    -- varialbe as done in stack, wrapping the exec with given cabal
    -- command.
    cabal = let cabal_args = [cabal_cmd, "-v0", "--", exec] ++ args
                hooks = fnkHooksWith "cabal" cabal_args False
            in  defaultMainWithHooks hooks

-- | Choose building action for /stack/ or /cabal-install/.
actWithStackOrCabal :: IO () -- ^ Main action for /stack/.
                    -> IO () -- ^ Main action for /cabal-install/.
                    -> IO ()
actWithStackOrCabal stack_act cabal_act = do
  exec_path <- getExecutablePath
  if ".stack" `isSubsequenceOf` exec_path
     then stack_act
     else cabal_act


-- ---------------------------------------------------------------------
--
-- UserHooks
--
-----------------------------------------------------------------------

-- | Make user hooks from compiler executable and extra arguments to the
-- executable.
fnkHooksWith :: FilePath -- ^ Compiler executable.
             -> [String] -- ^ Extra arguments to the executable.
             -> Bool     -- ^ Debug flag.
             -> UserHooks
fnkHooksWith exec args debug = simpleUserHooks
  { hookedPreProcessors = [registerFinkelPPHandler]
  , confHook            = fnkConfHookWith exec args debug
  , haddockHook         = fnkHaddockHooks
  }


-- ---------------------------------------------------------------------
--
-- Auxiliary
--
-- ---------------------------------------------------------------------

-- | Preprocessor suffix handler to merely register files with @"*.fnk"@
-- files.
registerFinkelPPHandler :: PPSuffixHandler
registerFinkelPPHandler = ("fnk", doNothingPP)
  where
    doNothingPP _ _ _ = PreProcessor
      { platformIndependent = True
      , runPreProcessor = mkSimplePreProcessor (\_ _ _ -> return ())
      }

fnkConfHookWith :: FilePath -- ^ Path to Finkel compiler.
                -> [String] -- ^ Extra default args to the Finkel
                            -- compiler.
                -> Bool     -- ^ Flag for debug.
                -> (GenericPackageDescription, HookedBuildInfo)
                -> ConfigFlags
                -> IO LocalBuildInfo
fnkConfHookWith fnk extra_args debug (pkg_descr, hbi) cflags = do
  lbi <- configure (pkg_descr, hbi) cflags
  return (overrideGhcAsFnk fnk extra_args debug lbi)

-- | Update @ghc@ program in 'LocalBuildInfo'.
overrideGhcAsFnk :: FilePath -- ^ Path to Finkel compiler.
                 -> [String] -- ^ Extra default args.
                 -> Bool     -- ^ Debug flag.
                 -> LocalBuildInfo
                 -> LocalBuildInfo
overrideGhcAsFnk fnk extra_args debug lbi = lbi'
  where
    lbi' = lbi {withPrograms = updateProgram ghc (withPrograms lbi)}
    ghc =
      case lookupProgram (simpleProgram "ghc") (withPrograms lbi) of
        Just ghc_orig ->
          ghc_orig {
              programLocation = FoundOnSystem fnk,
              programDefaultArgs =
                extra_args ++ programDefaultArgs ghc_orig,
              programOverrideArgs =
                programOverrideArgs ghc_orig ++ finkelflags
          }
        Nothing ->
          (simpleConfiguredProgram "ghc" (FoundOnSystem fnk)) {
            programDefaultArgs = extra_args,
            programOverrideArgs = finkelflags
          }
    finkelflags = debugs
    debugs = ["--fnk-debug"|debug]

-- | Haddock hooks for Finkel. Generates and cleans up Haskell source
-- codes from Finkel files during documentation generation.
fnkHaddockHooks :: PackageDescription
                -> LocalBuildInfo
                -> UserHooks
                -> HaddockFlags
                -> IO ()
fnkHaddockHooks pd lbi hooks flags = do
  (acquires, cleanups) <- mapAndUnzipM gen_hs_sources clbis
  bracket_ (sequence_ acquires)
           (sequence_ cleanups)
           (haddock pd lbi pps flags)
  where
    pps = allSuffixHandlers hooks
    clbis = toList (componentGraph lbi)
    gen_hs_sources clbi = do
      let name = componentLocalName clbi
          comp = getComponent pd name
          bi = componentBuildInfo comp
          cflags = configFlags lbi
          verbosity = case configVerbosity cflags of
                        Setup.Flag v -> v
                        NoFlag       -> Verbosity.normal
          autogen_dir = autogenComponentModulesDir lbi clbi
          pkg_dbs = withPackageDB lbi
          pkgs = componentIncludes clbi
          hs_src_dirs = hsSourceDirs bi
          other_mods = otherModules bi

      distPref <- findDistPrefOrDefault (configDistPref cflags)

      let internal_pkg_db =
            SpecificPackageDB (internalPackageDBPath lbi distPref)

      (hs_mods, hs_insts, hs_files) <-
         case comp of
           CLib {} -> do
             let ms = componentExposedModules clbi
                 is = componentInstantiatedWith clbi
                 ms' = foldr f [] ms
                   where
                     f em acc =
                       case exposedReexport em of
                         Nothing -> exposedName em : acc
                         Just _  -> acc
             return (ms' ++ other_mods, is, [])
           CExe exe -> do
             let path = modulePath exe
             return (other_mods, [], [path])
           _ -> return (other_mods, [], [])

      let opts = mempty
            { ghcOptMode             = flag GhcModeMake
            , ghcOptExtra            = optExtras autogen_dir
            , ghcOptInputFiles       = toNubListR hs_files
            , ghcOptInputModules     = toNubListR hs_mods
            , ghcOptSourcePathClear  = flag True
            , ghcOptSourcePath       = toNubListR hs_src_dirs'
            , ghcOptInstantiatedWith = hs_insts
            , ghcOptPackageDBs       = pkg_dbs ++ [internal_pkg_db]
            , ghcOptPackages         = toNubListR pkgs
            , ghcOptHideAllPackages  = flag True
            , ghcOptNoLink           = flag True
            }
          hs_src_dirs' = hs_src_dirs ++ [autogen_dir]
          flag = Setup.Flag
          cmpl = compiler lbi
          platform = hostPlatform lbi
          accumulateGeneratedFile acc m = do
            let p = toFilePath m
            mb_found <- findFile hs_src_dirs (p <.> "fnk")
            case mb_found of
              Just _found -> do
                let dest = autogen_dir </> p <.> "hs"
                return (dest:acc)
              Nothing    -> return acc

      gen_files <- foldM accumulateGeneratedFile [] hs_mods

      let ghc = simpleProgram "ghc"
          acquire =
            case lookupProgram ghc (withPrograms lbi) of
              Just prog | not (null gen_files) ->
                runGHC verbosity prog cmpl platform opts
              _                                -> return ()
          clean path = do
            exist <- doesFileExist path
            when exist (removeFile path)
          cleanup = mapM_ clean gen_files

      return (acquire, cleanup)

-- | Optional arguments passed to ghc, for writing Haskell source code
-- files from Finkel source code files.
#if MIN_VERSION_Cabal(2,4,0)
optExtras :: FilePath -> [String]
optExtras = optExtras'
#else
optExtras :: FilePath -> NubListR String
optExtras = toNubListR . optExtras'
#endif
  where
    optExtras' :: FilePath -> [String]
    optExtras' odir = ["-v0", "-fbyte-code", "--fnk-hsdir=" ++ odir]

-- | Same as the one used in "Distribution.Simple".
allSuffixHandlers :: UserHooks -> [PPSuffixHandler]
allSuffixHandlers hooks =
  overridesPP (hookedPreProcessors hooks) knownSuffixHandlers
    where overridesPP = unionBy ((==) `on` fst)
