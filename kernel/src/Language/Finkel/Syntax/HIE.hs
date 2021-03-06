{-# LANGUAGE CPP          #-}
{-# LANGUAGE TypeFamilies #-}
-- | Syntax for module header, import and export entities.
module Language.Finkel.Syntax.HIE where

-- ghc
import FastString                      (unpackFS)
import FieldLabel                      (FieldLbl (..))
import HsDoc                           (LHsDocString)
import HsImpExp                        (IE (..), IEWildcard (..),
                                        IEWrappedName (..),
                                        ImportDecl (..), simpleImportDecl)
import HsSyn                           (HsModule (..))
import Lexeme                          (isLexCon)
import Module                          (mkModuleNameFS)
import OccName                         (tcName)
import OrdList                         (toOL)
import RdrHsSyn                        (cvTopDecls)
import RdrName                         (mkQual, mkUnqual)
import SrcLoc                          (GenLocated (..), noLoc)

#if MIN_VERSION_ghc(8,6,0)
import HsExtension                     (noExt)
#endif

-- Internal
import Language.Finkel.Builder
import Language.Finkel.Form
import Language.Finkel.Syntax.SynUtils

#include "Syntax.h"

-- ---------------------------------------------------------------------
--
-- Module
--
-- ---------------------------------------------------------------------

-- In GHC source code, there is a file "compiler/hsSyn/Convert.hs".
-- This module contains codes converting Template Haskell data types to
-- GHC's internal data type, which is a helpful resource for
-- understanding the values and types for constructing Haskell AST data.

type ModFn =
  Maybe LHsDocString -> [HImportDecl] -> [HDecl] -> HModule

b_module :: Code -> [HIE] -> Builder ModFn
b_module (LForm (L l form)) exports
  | Atom (ASymbol name) <- form = return (modfn name)
  | otherwise                   = builderError
  where
    modfn name mbdoc imports decls =
      HsModule { hsmodName = Just (L l (mkModuleNameFS name))
               , hsmodExports = if null exports
                                   then Nothing
                                   else Just (L l exports)
               , hsmodImports = imports
               -- Function `cvTopDecls' is used for mergeing
               -- multiple top-level FunBinds, which possibly
               -- taking different patterns in its arguments.
               , hsmodDecls = cvTopDecls (toOL decls)
               , hsmodDeprecMessage = Nothing
               , hsmodHaddockModHeader = mbdoc }
{-# INLINE b_module #-}

b_implicitMainModule :: Builder ([HImportDecl] -> [HDecl] -> HModule)
b_implicitMainModule =
  do f <- b_module (LForm (noLoc (Atom (aSymbol "Main")))) []
     return (f Nothing)
{-# INLINE b_implicitMainModule #-}

b_ieSym :: Code -> Builder HIE
b_ieSym form@(LForm (L l _)) = do
  let thing x = L l (iEVar (L l (IEName (L l (mkRdrName x)))))
      iEVar = IEVar NOEXT
  name <- getVarOrConId form
  return (thing name)
{-# INLINE b_ieSym #-}

b_ieGroup :: Int -> Code -> Builder HIE
b_ieGroup n form@(LForm (L l body))
  | List [_, doc_code] <- body
  , Atom (AString doc) <- unCode doc_code
  = return $! L l (IEGroup NOEXT (fromIntegral n) (hsDocString doc))
  | otherwise
  = setLastToken form >> failB "Invalid group documentation"
{-# INLINE b_ieGroup #-}

b_ieDoc :: Code -> Builder HIE
b_ieDoc (LForm (L l form))
  | Atom (AString str) <- form =
    return $! L l (IEDoc NOEXT (hsDocString str))
  | otherwise = builderError
{-# INLINE b_ieDoc #-}

b_ieDocNamed :: Code -> Builder HIE
b_ieDocNamed (LForm (L l form))
  | List [_,name_code] <- form
  , Atom (ASymbol name) <- unCode name_code
  = return $! L l (IEDocNamed NOEXT (unpackFS name))
  | otherwise = builderError
{-# INLINE b_ieDocNamed #-}

b_ieAbs :: Code -> Builder HIE
b_ieAbs form@(LForm (L l _)) = do
  name <- getConId form
  let thing = L l (iEThingAbs (L l (IEName (L l (uq name)))))
      iEThingAbs = IEThingAbs NOEXT
      uq = mkUnqual tcName
  return thing
{-# INLINE b_ieAbs #-}

b_ieAll :: Code -> Builder HIE
b_ieAll form@(LForm (L l _)) = do
  name <- getConId form
  let thing = L l (iEThingAll (L l (IEName (L l (uq name)))))
      iEThingAll = IEThingAll NOEXT
      uq = mkUnqual tcName
  return thing
{-# INLINE b_ieAll #-}

b_ieWith :: Code -> [Code] -> Builder HIE
b_ieWith (LForm (L l form)) names
  | Atom (ASymbol name) <- form = return (thing name)
  | otherwise                   = builderError
  where
    thing name = L l (iEThingWith (L l (IEName (L l name'))) wc ns fs)
      where
        name' = case splitQualName name of
                  Just qual -> mkQual tcName qual
                  Nothing   -> mkUnqual tcName name
    wc = NoIEWildcard
    (ns, fs) = foldr f ([],[]) names
    f (LForm (L l0 (Atom (ASymbol n0)))) (ns0, fs0)
      | isLexCon n0 =
        (L l0 (IEName (L l (mkUnqual tcName n0))) : ns0, fs0)
      | otherwise   = (ns0, L l0 (fl n0) : fs0)
    f _ acc = acc
    -- Does not support DuplicateRecordFields.
    fl x = FieldLabel { flLabel = x
                      , flIsOverloaded = False
                      , flSelector = mkRdrName x }
    iEThingWith = IEThingWith NOEXT
{-# INLINE b_ieWith #-}

b_ieMdl :: [Code] -> Builder HIE
b_ieMdl xs
  | [LForm (L l (Atom (ASymbol name)))] <- xs = return (thing l name)
  | otherwise                                 = builderError
  where
    thing l n = L l (iEModuleContents (L l (mkModuleNameFS n)))
    iEModuleContents = IEModuleContents NOEXT
{-# INLINE b_ieMdl #-}

b_importD :: (Code, Bool, Maybe Code) -> (Bool, Maybe [HIE])
          -> Builder HImportDecl
b_importD (name, qualified, mb_as) (hiding, mb_entities)
  | LForm (L l (Atom (ASymbol m))) <- name =
    let decl = simpleImportDecl (mkModuleNameFS m)
        decl' = decl { ideclQualified = qualified
                     , ideclAs = fmap asModName mb_as
                     , ideclHiding = hiding' }
        asModName (LForm (L l' (Atom (ASymbol x)))) =
          L l' (mkModuleNameFS x)
        asModName _ = error "b_importD.asModName"
        hiding' =
          case mb_entities of
            Nothing       -> Nothing
            Just entities -> Just (hiding, L l entities)
    in  return (L l decl')
  | otherwise                              = builderError
{-# INLINE b_importD #-}
