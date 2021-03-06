{-# LANGUAGE CPP                  #-}
{-# LANGUAGE ConstraintKinds      #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}
-- | Emit Haskell source code from Haskell syntax data type.
--
-- This module contains types and functions for generating Haskell
-- source code from AST data types defined in ghc package.
--
-- The main purpose is to emit Haskell source code annotated with
-- documentation comments understood by hadddock, so the generated
-- result could be messy.
--
-- Most of the implementations are defined with 'ppr' function from
-- 'Outputable' type class.
--
module Language.Finkel.Emit
  ( HsSrc(..)
  , Hsrc(..)
  , genHsSrc
  ) where

-- base
#if MIN_VERSION_base(4,11,0)
import Prelude               hiding ((<>))
#endif
import Data.Function         (on)
import Data.List             (sortBy)
import Data.Maybe            (fromMaybe)

-- ghc
import Bag                   (bagToList, isEmptyBag)
import BasicTypes            (LexicalFixity (..), TopLevelFlag (..))
import Class                 (pprFundeps)
import GHC                   (OutputableBndrId, getPrintUnqual)
import GhcMonad              (GhcMonad (..), getSessionDynFlags)
import HsBinds               (LHsBinds, LSig, Sig (..), pprDeclList)
import HsDecls               (ConDecl (..), DocDecl (..), FamilyDecl (..),
                              FamilyInfo (..), FamilyResultSig (..),
                              HsDataDefn (..), HsDecl (..),
                              InjectivityAnn (..), LConDecl, LDocDecl,
                              LFamilyDecl, LTyFamDefltEqn, TyClDecl (..),
                              TyFamInstEqn)
import HsDoc                 (LHsDocString)
import HsImpExp              (IE (..), LIE)
import HsSyn                 (HsModule (..))
import HsTypes               (ConDeclField (..), HsConDetails (..),
                              HsContext, HsImplicitBndrs (..), HsType (..),
                              HsWildCardBndrs (..), LConDeclField,
                              LHsQTyVars (..), LHsTyVarBndr, LHsType,
                              pprHsForAll)
import Outputable            (Outputable (..), OutputableBndr (..), SDoc,
                              braces, char, comma, darrow, dcolon, dot,
                              empty, equals, forAllLit, fsep, hang, hsep,
                              interpp'SP, interppSP, lparen, nest, parens,
                              pprWithCommas, punctuate, sep,
                              showSDocForUser, text, vbar, vcat, ($$),
                              ($+$), (<+>), (<>))
import RdrName               (RdrName)
import SrcLoc                (GenLocated (..), Located, noLoc, unLoc)

#if MIN_VERSION_ghc(8,8,0)
import HsDecls               (pprHsFamInstLHS)
#elif MIN_VERSION_ghc(8,4,0)
import HsDecls               (pprFamInstLHS)
#endif

#if MIN_VERSION_ghc(8,4,0)
import HsDecls               (FamEqn (..))
#else
import HsDecls               (HsTyPats, TyFamEqn (..))
#endif

#if MIN_VERSION_ghc(8,8,0)
import HsTypes               (noLHsContext, pprLHsContext)
#else
import HsTypes               (pprHsContext)
#endif

#if MIN_VERSION_ghc(8,6,0)
import Outputable            (arrow, pprPanic)
#endif

#if MIN_VERSION_ghc(8,4,0)
import HsExtension           (IdP)
#else
#define IdP {- empty -}
#endif

#if MIN_VERSION_ghc(8,6,0)
import HsDoc                 (HsDocString, unpackHDS)
#else
import FastString            (unpackFS)
import HsDoc                 (HsDocString (..))
#endif

-- For SourceTextX, transitional type used in ghc 8.4.x.
#if MIN_VERSION_ghc(8,6,0)
import HsExtension           (GhcPass)
#elif MIN_VERSION_ghc(8,4,0)
import HsExtension           (SourceTextX)
#endif

-- For ghc < 8.4
#if !MIN_VERSION_ghc(8,4,0)
import HsTypes               (pprParendHsType)
import OccName               (HasOccName (..))
#endif

-- Internal
import Language.Finkel.Lexer

#include "Syntax.h"


-- ---------------------------------------------------------------------
--
-- Constraints for Outputable
--
-- ---------------------------------------------------------------------

#if MIN_VERSION_ghc(8,6,0)
type OUTPUTABLE a pr = (OutputableBndrId a, a ~ GhcPass pr)
#elif MIN_VERSION_ghc(8,4,0)
type OUTPUTABLE a pr = (OutputableBndrId a, SourceTextX a)
#else
type OUTPUTABLE a pr = (OutputableBndrId a, HsSrc a)
#endif

#if MIN_VERSION_ghc(8,4,0)
type OUTPUTABLEOCC a pr = (OUTPUTABLE a pr)
#else
type OUTPUTABLEOCC a pr = (OUTPUTABLE a pr, HasOccName a)
#endif


-- ---------------------------------------------------------------------
--
-- Annotation dictionary
--
-- ---------------------------------------------------------------------

{-
isDocComment :: Located AnnotationComment -> Bool
isDocComment x =
  case unLoc x of
    AnnDocCommentNext _  -> True
    AnnDocCommentPrev _  -> True
    AnnDocCommentNamed _ -> True
    AnnDocSection _ _    -> True
    _                    -> False

buildDocMap :: [Located AnnotationComment] -> DocMap
buildDocMap acs = go (Map.empty, Nothing, []) (sortLocated acs)
  where
    go :: ( Map.Map SrcSpan [AnnotationComment]
          , Maybe SrcSpan
          , [AnnotationComment] )
       -> [Located AnnotationComment]
       -> DocMap
    go (acc, keySpan, block) [] =
      case keySpan of
        Nothing -> acc
        Just k  -> Map.insert k (reverse block) acc
    go (acc, keySpan, block) (com:coms) =
      case keySpan of
        Just k ->
          case (k, getLoc com) of
            (RealSrcSpan k', RealSrcSpan com') ->
              if (srcSpanEndLine k' + 1) == srcSpanStartLine com'
                 then go ( acc
                         , Just (combineSrcSpans k (getLoc com))
                         , unLoc com:block )
                         coms
                 else
                   let acc' = Map.insert k (reverse block) acc
                       isDoc = isDocComment com
                       keySpan' | isDoc = Just (getLoc com)
                                | otherwise = Nothing
                       block' | isDoc = [unLoc com]
                              | otherwise = []
                   in  go (acc', keySpan', block') coms
            _ -> go (acc, Nothing, []) coms
        Nothing ->
          if isDocComment com
             then go (acc, Just (getLoc com), [unLoc com]) coms
             else go (acc, Nothing, block) coms

spanStartLine :: SrcSpan -> Int
spanStartLine l =
  case l of
    RealSrcSpan s -> srcSpanStartLine s
    _             -> -1

spanEndLine :: SrcSpan -> Int
spanEndLine l =
  case l of
    RealSrcSpan s -> srcSpanEndLine s
    _             -> -1

-- | Lookup previous documentation comment.
--
-- Here @previous@ means the end line of documentation comment matches
-- to the start line of reference span - offset.
--
lookupPrevDoc :: Int -> SrcSpan -> DocMap -> Maybe [AnnotationComment]
lookupPrevDoc offset l =
  let line = spanStartLine l
      f k a | spanEndLine k == line - offset = Just a
            | otherwise                      = Nothing
  in  Map.foldMapWithKey f

emitPrevDoc :: SPState -> Located a -> SDoc
emitPrevDoc = emitPrevDocWithOffset 1

emitPrevDocWithOffset :: Int -> SPState -> Located a -> SDoc
emitPrevDocWithOffset offset st ref =
  case lookupPrevDoc offset (getLoc ref) (docMap st) of
    Nothing -> empty
    Just as -> vcat (map f as)
  where
    f annotated = case annotated of
      AnnDocCommentNext doc -> case lines doc of
        c:cs -> vcat ((text "-- | " <> text c):
                      map (\ x -> text "--" <> text x) cs)
        []   -> empty
      AnnLineComment doc -> text "-- " <> text doc
      _                  -> ppr annotated

#if !MIN_VERSION_ghc(8,4,0)
-- | 'whenPprDebug' does not exist in ghc 8.2. Defining one with
-- 'ifPprDebug'. Also, number of arguments in 'ifPprDebug' changed in
-- ghc 8.4.
whenPprDebug :: SDoc -> SDoc
whenPprDebug d = ifPprDebug d
#endif

-}


-- ---------------------------------------------------------------------
--
-- HsSrc class
--
-- ---------------------------------------------------------------------

-- | Type class for generating textual source code.
class HsSrc a where
  toHsSrc :: SPState -> a -> SDoc

-- | A wrapper type to specify instance of 'HsSrc'.
newtype Hsrc a = Hsrc {unHsrc :: a}

-- | Generate textual source code from given data.
genHsSrc :: (GhcMonad m, HsSrc a) => SPState -> a -> m String
genHsSrc st0 x = do
  flags <- getSessionDynFlags
  unqual <- getPrintUnqual
  return (showSDocForUser flags unqual (toHsSrc st0 x))


-- ---------------------------------------------------------------------
--
-- Instances
--
-- ---------------------------------------------------------------------

instance HsSrc RdrName where
  toHsSrc _ = ppr

instance (HsSrc b) => HsSrc (GenLocated a b) where
  toHsSrc st (L _ e) = toHsSrc st e

instance OUTPUTABLEOCC a pr => HsSrc (Hsrc (HsModule a)) where
  toHsSrc st a = case unHsrc a of
    HsModule Nothing _ imports decls _ mbDoc ->
      vcat [ pp_langExts st
           , pp_mbdocn mbDoc
           , pp_nonnull imports
           , hsSrc_nonnull st (map unLoc decls)
           , text "" ]
    HsModule (Just name) exports imports decls deprec mbDoc ->
      vcat [ pp_langExts st
           , pp_mbdocn mbDoc
           , case exports of
               Nothing ->
                 pp_header (text "where")
               Just es ->
                 vcat [ pp_header lparen
                      , nest 8 (pp_lies st (unLoc es))
                      , nest 4 (text ") where")]
           , pp_nonnull imports
           , hsSrc_nonnull st (map unLoc decls)
           , text "" ]
      where
        pp_header rest =
          case deprec of
            Nothing -> pp_modname <+> rest
            Just d  -> vcat [pp_modname, ppr d, rest]
        pp_modname = text "module" <+> ppr name

instance OUTPUTABLEOCC a pr => HsSrc (Hsrc (IE a)) where
  toHsSrc _st (Hsrc ie) =
    case ie of
      IEGroup _EXT n doc  -> commentWithHeader ("-- " ++ replicate n '*')
                                                doc
      IEDoc _EXT doc      -> commentWithHeader ("-- |") doc
      IEDocNamed _EXT doc -> text ("-- $" ++ doc)
      _                   -> ppr ie


-- --------------------------------------------------------------------
--
-- Top level declarations
--
-----------------------------------------------------------------------

instance OUTPUTABLE a pr => HsSrc (HsDecl a) where
  toHsSrc st decl =
    case decl of
      SigD  _EXT sig   -> toHsSrc st sig
      TyClD _EXT tycld -> toHsSrc st tycld
      DocD _EXT doc    -> toHsSrc st doc
      _                -> ppr decl


-- --------------------------------------------------------------------
--
-- Type signature
--
-----------------------------------------------------------------------

instance OUTPUTABLE a pr => HsSrc (Sig a) where
  toHsSrc st sig = case sig of
    TypeSig _EXT vars ty -> pprVarSig (map unLoc vars)
                                      (toHsSrc st ty)
    ClassOpSig _EXT is_dflt vars ty
      | is_dflt   -> text "default" <+> pprVarSig (map unLoc vars)
                                                  (toHsSrc st ty)
      | otherwise -> pprVarSig (map unLoc vars) (toHsSrc st ty)
    _ -> ppr sig

instance (OUTPUTABLE a pr, Outputable thing, HsSrc thing)
          => HsSrc (HsWildCardBndrs a thing) where
  toHsSrc st wc = case wc of
    HsWC { hswc_body = ty } -> toHsSrc st ty
#if MIN_VERSION_ghc(8,6,0)
    _                       -> ppr wc
#endif

instance (OUTPUTABLE a pr)
         => HsSrc (HsImplicitBndrs a (LHsType a)) where
  toHsSrc st ib =
    case ib of
      HsIB { hsib_body = ty } -> toHsSrc st ty
#if MIN_VERSION_ghc(8,6,0)
      _                       -> ppr ib
#endif

instance (OUTPUTABLE a pr) => HsSrc (HsType a) where
  toHsSrc st ty = case ty of
    HsForAllTy {hst_bndrs=tvs, hst_body=ty1} ->
      sep [pprHsForAllTvs tvs, hsrc ty1]
    HsQualTy {hst_ctxt=L _ ctxt, hst_body=ty1} ->
      sep [pprHsContextAlways ctxt, hsrc ty1]
    HsFunTy _EXT ty1 ty2 ->
      sep [hsrc ty1, text "->", hsrc ty2]
    HsDocTy _EXT ty' (L _ docstr) ->
      ppr ty' $+$ commentWithHeader "-- ^" docstr
    HsParTy _EXT ty1 -> parens (hsrc ty1)
    _ -> ppr ty
    where
      hsrc :: HsSrc a => a -> SDoc
      hsrc = toHsSrc st

-- From 'HsBinds.pprVarSig'.
pprVarSig :: OutputableBndr id => [id] -> SDoc -> SDoc
pprVarSig vars pp_ty = sep [pprvars <+> dcolon, nest 2 pp_ty]
  where
    pprvars = hsep $ punctuate comma (map pprPrefixOcc vars)

-- From 'HsTypes.pprHsForAllTvs'.
pprHsForAllTvs :: OUTPUTABLE n pr => [LHsTyVarBndr n] -> SDoc
pprHsForAllTvs qtvs
  | null qtvs = forAllLit <+> dot
  | otherwise = forAllLit <+> interppSP qtvs <> dot

-- From 'HsTypes.pprHsContextAlways'.
pprHsContextAlways :: OUTPUTABLE n pr => HsContext n -> SDoc
pprHsContextAlways []       = parens empty <+> darrow
pprHsContextAlways [L _ ty] = ppr ty <+> darrow
pprHsContextAlways cxt      = parens (interpp'SP cxt) <+> darrow


-- --------------------------------------------------------------------
--
-- TyClDecl
--
-- --------------------------------------------------------------------

instance OUTPUTABLE a pr => HsSrc (TyClDecl a) where
  toHsSrc st tcd =
    case tcd of
      SynDecl { tcdLName = ltycon, tcdTyVars = tyvars
              , tcdFixity = fixity, tcdRhs = rhs } ->
        hang (text "type" <+>
              pp_vanilla_decl_head ltycon tyvars fixity [] <+> equals)
           4 (toHsSrc st rhs)
      DataDecl { tcdLName = ltycon, tcdTyVars = tyvars
               , tcdFixity = fixity, tcdDataDefn = defn } ->
        pp_data_defn st (pp_vanilla_decl_head ltycon tyvars fixity) defn
      ClassDecl { tcdCtxt = context, tcdLName = lclas
                , tcdTyVars = tyvars, tcdFixity = fixity
                , tcdFDs = fds, tcdSigs = sigs, tcdMeths = methods
                , tcdATs = ats, tcdATDefs = at_defs
                , tcdDocs = docs }
        | null sigs && isEmptyBag methods && null ats && null at_defs
        -> top_matter
        | otherwise
        -> vcat
             [ top_matter <+> text "where"
             , nest 2
                    (pprDeclList
                      (ppr_cdecl_body st ats at_defs methods sigs docs))]
        where
          top_matter =
            text "class"
            <+> pp_vanilla_decl_head lclas tyvars fixity (unLoc context)
            <+> pprFundeps (map unLoc fds)
      _ -> ppr tcd


-- --------------------------------------------------------------------
--
-- For SynDecl and DataDecl
--
-- --------------------------------------------------------------------

pp_data_defn :: (OUTPUTABLE n pr)
             => SPState
             -> (HsContext n -> SDoc)
             -> HsDataDefn n
             -> SDoc
pp_data_defn
  st pp_hdr (HsDataDefn { dd_ND = new_or_data, dd_ctxt = L _ context
                        , dd_cType = mb_ct, dd_kindSig = mb_sig
                        , dd_cons = condecls, dd_derivs = derivings })
  | null condecls
  = ppr new_or_data <+> pp_ct <+> pp_hdr context <+> pp_sig
    <+> pp_derivings derivings
  | otherwise
  = hang (ppr new_or_data <+> pp_ct <+> pp_hdr context <+> pp_sig)
       2 (pp_condecls st condecls $$ pp_derivings derivings)
  where
    pp_ct = case mb_ct of
              Nothing -> empty
              Just ct -> ppr ct
    pp_sig = case mb_sig of
               Nothing   -> empty
               Just kind -> dcolon <+> ppr kind
    pp_derivings (L _ ds) = vcat (map ppr ds)
#if MIN_VERSION_ghc(8,6,0)
pp_data_defn _ _ (XHsDataDefn x) = ppr x
#endif

-- Modified version of 'HsDecls.pp_condecls', no space in front of "|",
-- taking 'SPState' as first argument.
pp_condecls :: (OUTPUTABLE n pr) => SPState -> [LConDecl n] -> SDoc
pp_condecls st cs@(L _ ConDeclGADT {} : _) =
  hang (text "where") 2 (vcat (map (pprConDecl st . unLoc) cs))
pp_condecls st cs =
  equals <+> sep (punctuate (text " |") (map (pprConDecl st . unLoc) cs))

-- Modified version of 'HsDecls.pprConDecl'. This function does the
-- pretty printing of documentation for constructors.
--
-- Although the syntax parser for constructor documentation accepts
-- ":docp" form, this function emit documentation before the constructor
-- declaration, to support documentation for constructor argument. This
-- is because haddock may concatenate the docstring for the last
-- constructor argument and the docstring for constructor itself.
pprConDecl :: OUTPUTABLE n pr => SPState -> ConDecl n -> SDoc
pprConDecl st condecl@(ConDeclH98 {}) =
  pp_mbdocn doc $+$ sep [pprHsForAll tvs cxt, ppr_details details]
  where
#if MIN_VERSION_ghc(8,6,0)
    ConDeclH98 { con_name = L _ con
               , con_ex_tvs = tvs
               , con_mb_cxt = mcxt
               , con_args = details
               , con_doc = doc } = condecl
#else
    ConDeclH98 { con_name = L _ con
               , con_qvars = mtvs
               , con_cxt = mcxt
               , con_details = details
               , con_doc = doc } = condecl
    tvs = maybe [] hsq_explicit mtvs
#endif
    ppr_details (InfixCon t1 t2) =
      hsep [hsrc t1, pprInfixOcc con, hsrc t2]
    ppr_details (PrefixCon tys) =
      sep (pprPrefixOcc con : map (hsrc . unLoc) tys)
    ppr_details (RecCon fields) =
      pprPrefixOcc con <+> pprConDeclFields (unLoc fields)
    cxt = fromMaybe (noLoc []) mcxt
    hsrc :: HsSrc a => a -> SDoc
    hsrc = toHsSrc st

#if MIN_VERSION_ghc(8,6,0)
pprConDecl st (ConDeclGADT { con_names = cons
                           , con_qvars = qvars
                           , con_mb_cxt = mcxt
                           , con_args = args
                           , con_res_ty = res_ty
                           , con_doc = doc })
  = pp_mbdocn doc $+$ ppr_con_names cons <+> dcolon
    <+> (sep [pprHsForAll (hsq_explicit qvars) cxt
             ,ppr_arrow_chain (get_args args ++ [hsrc res_ty])])
  where
    get_args (PrefixCon as)  = map hsrc as
    get_args (RecCon fields) = [pprConDeclFields (unLoc fields)]
    get_args (InfixCon {})   = pprPanic "pprConDecl:GADT" (ppr cons)
    cxt = fromMaybe (noLoc []) mcxt
    ppr_arrow_chain []     = empty
    ppr_arrow_chain (a:as) = sep (a : map (arrow <+>) as)
    hsrc :: HsSrc a => a -> SDoc
    hsrc = toHsSrc st
pprConDecl _ con = ppr con
#else
pprConDecl st (ConDeclGADT { con_names = cons
                           , con_type = res_ty
                           , con_doc = doc })
  = pp_mbdocn doc $+$
    sep [ppr_con_names cons <+> dcolon <+> toHsSrc st res_ty]
#endif

-- From 'HsDecls.ppr_con_names'.
ppr_con_names :: OutputableBndr a => [Located a] -> SDoc
ppr_con_names = pprWithCommas (pprPrefixOcc . unLoc)

-- Modified version of 'HsTypes.pprConDeclFields', to emit documentation
-- comments of fields in record data type.
pprConDeclFields :: OUTPUTABLE n pr
                  => [LConDeclField n] -> SDoc
pprConDeclFields fields =
  braces (sep (punctuate comma (map ppr_fld fields)))
  where
    ppr_fld (L _ (ConDeclField { cd_fld_names = ns
                               , cd_fld_type = ty
                               , cd_fld_doc = doc }))
      = ppr_names ns <+> dcolon <+> ppr ty
        $+$ pp_mbdocp doc $+$ text ""
#if MIN_VERSION_ghc(8,6,0)
    ppr_fld (L _ (XConDeclField x)) = ppr x
#endif
    ppr_names [n] = ppr n
    ppr_names ns  = sep (punctuate comma (map ppr ns))

-- From 'HsDecls.pp_vanilla_decl_head'.
pp_vanilla_decl_head :: (OUTPUTABLE n pr)
                     => Located (IdP n)
                     -> LHsQTyVars n
                     -> LexicalFixity
                     -> HsContext n
                     -> SDoc
pp_vanilla_decl_head thing (HsQTvs {hsq_explicit=tyvars}) fixity context
  = hsep [pprHsContext context, pp_tyvars tyvars]
  where
    pp_tyvars (varl:varsr)
      | fixity == Infix && length varsr > 1
      = hsep [ char '(', ppr (unLoc varl), pprInfixOcc (unLoc thing)
             , ppr (unLoc (head varsr)), char ')'
             , hsep (map (ppr . unLoc) (tail varsr)) ]
      | fixity == Infix
      = hsep [ ppr (unLoc varl), pprInfixOcc (unLoc thing)
             , hsep (map (ppr . unLoc) varsr) ]
      | otherwise = hsep [ pprPrefixOcc (unLoc thing)
                         , hsep (map (ppr . unLoc) (varl: varsr)) ]
    pp_tyvars [] = pprPrefixOcc (unLoc thing)
#if MIN_VERSION_ghc(8,6,0)
pp_vanilla_decl_head _ (XLHsQTyVars x) _ _ = ppr x
#endif


-- --------------------------------------------------------------------
--
-- For ClassDecl
--
-- --------------------------------------------------------------------

ppr_cdecl_body :: OUTPUTABLE n pr
               => SPState
               -> [LFamilyDecl n]
               -> [LTyFamDefltEqn n]
               -> LHsBinds n
               -> [LSig n]
               -> [LDocDecl]
               -> [SDoc]
ppr_cdecl_body st ats at_defs methods sigs docs = map snd body
  where
    body = sortBy (compare `on` fst) body0
    body0 =
      map (\(L l at) -> (l, pprFamilyDecl NotTopLevel at)) ats ++
      map (\d@(L l _) -> (l, ppr_fam_deflt_eqn d)) at_defs ++
      map (\(L l sig) -> (l, toHsSrc st sig)) sigs ++
      map (\(L l bind) -> (l, ppr bind)) (bagToList methods) ++
      map (\(L l doc) -> (l, toHsSrc st doc)) docs

-- From 'HsDecls.pprFamilyDecl'. Used during pretty printing type class
-- body contents, with first argument set to 'NonTopLevel'.
pprFamilyDecl :: (OUTPUTABLE n pr)
              => TopLevelFlag -> FamilyDecl n -> SDoc
pprFamilyDecl top_level (FamilyDecl { fdInfo = info, fdLName = ltycon
                                    , fdTyVars = tyvars
                                    , fdFixity = fixity
                                    , fdResultSig = L _ result
                                    , fdInjectivityAnn = mb_inj })
  = vcat [ pprFlavour info <+> pp_top_level <+>
           pp_vanilla_decl_head ltycon tyvars fixity [] <+>
           pp_kind <+> pp_inj <+> pp_where
         , nest 2 $ pp_eqns ]
  where
    pp_top_level = case top_level of
                     TopLevel    -> text "family"
                     NotTopLevel -> empty

    pp_kind = case result of
                NoSig    _EXT         -> empty
                KindSig  _EXT kind    -> dcolon <+> ppr kind
                TyVarSig _EXT tv_bndr -> text "=" <+> ppr tv_bndr
#if MIN_VERSION_ghc(8,6,0)
                XFamilyResultSig x    -> ppr x
#endif
    pp_inj = case mb_inj of
               Just (L _ (InjectivityAnn lhs rhs)) ->
                 hsep [ vbar, ppr lhs, text "->", hsep (map ppr rhs) ]
               Nothing -> empty
    (pp_where, pp_eqns) = case info of
      ClosedTypeFamily mb_eqns ->
        ( text "where"
        , case mb_eqns of
            Nothing   -> text ".."
            Just eqns -> vcat $ map (ppr_fam_inst_eqn . unLoc) eqns )
      _ -> (empty, empty)
#if MIN_VERSION_ghc(8,6,0)
pprFamilyDecl _ (XFamilyDecl x) = ppr x
#endif

-- From 'HsDecls.pprFlavour'.
pprFlavour :: FamilyInfo pass -> SDoc
pprFlavour DataFamily            = text "data"
pprFlavour OpenTypeFamily        = text "type"
pprFlavour (ClosedTypeFamily {}) = text "type"

-- From 'HsDecls.ppr_fam_inst_eqn'
ppr_fam_inst_eqn :: (OUTPUTABLE n pr) => TyFamInstEqn n -> SDoc
#if MIN_VERSION_ghc(8,8,0)
ppr_fam_inst_eqn (HsIB { hsib_body = FamEqn { feqn_tycon = L _ tycon
                                            , feqn_bndrs = bndrs
                                            , feqn_pats = pats
                                            , feqn_fixity = fixity
                                            , feqn_rhs = rhs }})
    = pprHsFamInstLHS tycon bndrs pats fixity noLHsContext <+>
      equals <+> ppr rhs
ppr_fam_inst_eqn (XHsImplicitBndrs x) = ppr x
ppr_fam_inst_eqn _ = error "ppr_fam_inst_eqn"
#elif MIN_VERSION_ghc(8,6,0)
ppr_fam_inst_eqn (HsIB { hsib_body = FamEqn { feqn_tycon  = tycon
                                            , feqn_pats   = pats
                                            , feqn_fixity = fixity
                                            , feqn_rhs    = rhs }})
    = pprFamInstLHS tycon pats fixity [] Nothing <+> equals <+> ppr rhs
ppr_fam_inst_eqn (HsIB { hsib_body = XFamEqn x }) = ppr x
ppr_fam_inst_eqn (XHsImplicitBndrs x) = ppr x
#elif MIN_VERSION_ghc(8,4,0)
ppr_fam_inst_eqn (HsIB { hsib_body = FamEqn { feqn_tycon  = tycon
                                            , feqn_pats   = pats
                                            , feqn_fixity = fixity
                                            , feqn_rhs    = rhs }})
    = pprFamInstLHS tycon pats fixity [] Nothing <+> equals <+> ppr rhs
#else
ppr_fam_inst_eqn (TyFamEqn { tfe_tycon = tycon
                           , tfe_pats  = pats
                           , tfe_fixity = fixity
                           , tfe_rhs   = rhs })
    = pp_fam_inst_lhs tycon pats fixity [] <+> equals <+> ppr rhs

-- From 'HsDecls.pp_fam_inst_lhs'
pp_fam_inst_lhs :: (OutputableBndrId name) => Located name
   -> HsTyPats name
   -> LexicalFixity
   -> HsContext name
   -> SDoc
pp_fam_inst_lhs thing (HsIB { hsib_body = typats }) fixity context
                                              -- explicit type patterns
   = hsep [pprHsContext context, pp_pats typats]
   where
     pp_pats (patl:patsr)
       | fixity == Infix
          = hsep [pprParendHsType (unLoc patl), pprInfixOcc (unLoc thing)
          , hsep (map (pprParendHsType.unLoc) patsr)]
       | otherwise = hsep [ pprPrefixOcc (unLoc thing)
                   , hsep (map (pprParendHsType.unLoc) (patl:patsr))]
     pp_pats [] = empty
#endif

-- From 'HsDecls.ppr_fam_deflt_eqn'
ppr_fam_deflt_eqn :: OUTPUTABLE n pr => LTyFamDefltEqn n -> SDoc
#if MIN_VERSION_ghc(8,4,0)
ppr_fam_deflt_eqn (L _ (FamEqn { feqn_tycon  = tycon
                               , feqn_pats   = tvs
                               , feqn_fixity = fixity
                               , feqn_rhs    = rhs }))
#else
ppr_fam_deflt_eqn (L _ (TyFamEqn { tfe_tycon = tycon
                                 , tfe_pats = tvs
                                 , tfe_fixity = fixity
                                 , tfe_rhs = rhs }))
#endif
  = text "type" <+> pp_vanilla_decl_head tycon tvs fixity []
                <+> equals <+> ppr rhs
#if MIN_VERSION_ghc(8,6,0)
ppr_fam_deflt_eqn (L _ (XFamEqn x)) = ppr x
#endif

-- ---------------------------------------------------------------------
--
-- DocDecl
--
-- ---------------------------------------------------------------------

instance HsSrc DocDecl where
  toHsSrc _st d = case d of
    DocCommentNext ds       -> text "" $+$ commentWithHeader "-- |" ds
    DocCommentPrev ds       -> text "" $+$ commentWithHeader "-- ^" ds
                               $+$ text ""
    DocCommentNamed name ds -> namedDoc name ds
    DocGroup n ds           -> let stars = replicate n '*'
                               in  commentWithHeader ("-- " ++ stars) ds
    where
      namedDoc name doc =
        let body = map (\x -> text "--" <+> text x)
                       (lines (unpackHDS' doc))
        in  vcat (text "" : text ("-- $" ++ name) : text "--" : body)


-- -------------------------------------------------------------------
--
-- Auxiliary
--
-- -------------------------------------------------------------------

pp_nonnull :: Outputable t => [t] -> SDoc
pp_nonnull [] = empty
pp_nonnull xs = vcat (map ppr xs)

pp_mbdocn :: Maybe LHsDocString -> SDoc
pp_mbdocn = maybe empty (commentWithHeader "-- |" . unLoc)

pp_mbdocp :: Maybe LHsDocString -> SDoc
pp_mbdocp = maybe empty (commentWithHeader "-- ^" . unLoc)

pp_langExts :: SPState -> SDoc
pp_langExts sp = vcat (map f (langExts sp))
  where
    f (L _ e) = text "{-# LANGUAGE" <+> text e <+> text "#-}"

hsSrc_nonnull :: HsSrc a => SPState -> [a] -> SDoc
hsSrc_nonnull st xs =
  case xs of
    [] -> empty
    _  -> vcat (map (toHsSrc st) xs)

commentWithHeader :: String -> HsDocString -> SDoc
commentWithHeader header doc =
  case lines (unpackHDS' doc) of
    []   -> empty
    d:ds -> vcat ((text header <+> text d):
                  map (\ x -> text "--" <+> text x) ds)

-- | Format located export elements.
--
-- This function converts module export elements and comments to 'SDoc'.
-- Export elements are punctuated with commas, and newlines are inserted
-- between documentation comments.
pp_lies :: OUTPUTABLEOCC a pr => SPState -> [LIE a] -> SDoc
pp_lies st = go
  where
    go [] = empty
    go ds =
      case break (isDocIE . unLoc) ds of
        (nondocs, rest) ->
          let sdoc = fsep (punctuate comma (map (toHsSrc st . Hsrc . unLoc)
                                                nondocs))
              sdoc' = case nondocs of
                        [] -> sdoc
                        _  -> sdoc <> comma
          in  case rest of
                []        -> sdoc
                doc:rest' -> sdoc'
                             $+$ toHsSrc st (Hsrc (unLoc doc))
                             $+$ go rest'

-- | 'True' when the argument is for documentation.
isDocIE :: IE a -> Bool
isDocIE ie =
  case ie of
    IEGroup {}    -> True
    IEDoc {}      -> True
    IEDocNamed {} -> True
    _             -> False

-- | GHC version compatible function for unpacking 'HsDocString'.
unpackHDS' :: HsDocString -> String
#if MIN_VERSION_ghc(8,6,0)
unpackHDS' = unpackHDS
#else
unpackHDS' (HsDocString fs) = unpackFS fs
#endif

#if MIN_VERSION_ghc(8,8,0)
-- | GHC version compatible function for pretty printing 'HsContext'.
pprHsContext :: OUTPUTABLE n a => HsContext (GhcPass a) -> SDoc
pprHsContext = pprLHsContext . noLoc
#endif
