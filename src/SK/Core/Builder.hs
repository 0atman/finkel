{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
-- | Builder functions for Haskell syntax data type.
module SK.Core.Builder where

-- base
import Control.Monad (liftM, ap)
import Data.Char (isUpper)
import Data.Either (partitionEithers)
import Data.List (foldl1')

-- transformers
import Control.Monad.Trans.Except
import Control.Monad.Trans.State

-- Internal
import SK.Core.GHC
import SK.Core.Form

-- | State for 'Builder'.
data BState = BState
    { -- | Input tokens to parse.
      inputs :: [LTForm Atom]
      -- | Last token, for error message.
    , lastToken :: Maybe (LTForm Atom)
    }

-- | Newtype wrapper for parsing form data with Happy.
newtype Builder a = Builder {
    unBuilder :: StateT BState (Either String) a
}

runBuilder :: Builder a
           -> [LTForm Atom]
           -> Either String (a, [LTForm Atom])
runBuilder bld toks =
    case runStateT (unBuilder bld) (BState toks Nothing) of
      Left e -> Left e
      Right (a, st) -> Right (a, inputs st)

evalBuilder :: Builder a -> [LTForm Atom] -> Either String a
evalBuilder bld toks = fmap fst (runBuilder bld toks)

evalBuilder' :: Monad m
             => Builder a
             -> [LTForm Atom]
             -> ExceptT String m a
evalBuilder' bld toks = case evalBuilder bld toks of
  Right a -> return a
  Left err -> throwE err

failB :: String -> Builder a
failB err = Builder (StateT (\_ -> Left err))

instance Functor Builder where
    fmap = liftM

instance Applicative Builder where
    pure = return
    (<*>) = ap

instance Monad Builder where
  return a = Builder (return a)
  m >>= k  =
      Builder
        (StateT (\st ->
                   case runStateT (unBuilder m) st of
                     Right (a,st') -> runStateT (unBuilder (k a)) st'
                     Left err -> Left err))

getBState :: Builder BState
getBState = Builder get

putBState :: BState -> Builder ()
putBState = Builder . put

-- | Parse with builder using given tokens, continue on successful
-- parse.
parse :: Builder a -> [LTForm Atom] -> Builder a
parse bld toks = do
  case runBuilder bld toks of
    Right (a, _) -> return a
    Left err -> failB err

-- | String representation of located data.
showLoc :: Located a -> String
showLoc x = case getLoc x of
      RealSrcSpan r ->
        unpackFS (srcSpanFile r) ++ ":" ++
        show (srcSpanStartLine r) ++ ":" ++
        show (srcSpanStartCol r) ++ ": "
      UnhelpfulSpan _ -> "unknown location"

-- | Simple lexer to parse forms.
formLexer :: (LTForm Atom -> Builder a) -> Builder a
formLexer cont = do
    st <- getBState
    case inputs st of
      [] -> cont (L undefined TEnd)
      x:xs -> do
        putBState (st {inputs = xs, lastToken = Just x})
        cont x


---
--- Type synonyms
---

type HExpr = LHsExpr RdrName

type HDecl = LHsDecl RdrName

type HConDecl = LConDecl RdrName

type HConDeclField = LConDeclField RdrName

type HsQTyVars = LHsQTyVars RdrName

type HTyVarBndr = LHsTyVarBndr RdrName

type HBind = LHsBind RdrName

type HSigWcType = LHsSigWcType RdrName

type HType = LHsType RdrName

type HPat = LPat RdrName

type HExprLStmt = ExprLStmt RdrName

type HLocalBinds = Located (HsLocalBinds RdrName)

type HMatch = LMatch RdrName HExpr

type HGRHS = LGRHS RdrName HExpr

type HGuardLStmt = GuardLStmt RdrName

type HImportDecl = LImportDecl RdrName


--
-- Auxiliary
--

builderError :: Builder a
builderError = do
  st <- getBState
  case lastToken st of
    Nothing -> failB "no location"
    Just x  ->
      failB (showLoc x ++ "parse error on input `" ++
             (show (pForm (lTFormToForm x))) ++ "'")


-- | Unwrap the element of 'TList' and 'THsList', otherwise returns '[]'.
unwrapListL :: LTForm Atom -> [LTForm Atom]
unwrapListL (L _ form) =
    case form of
      TList xs -> xs
      THsList xs -> xs
      _ -> []

-- XXX: Currently, cannot tell the difference between 'Qualified.fun'
-- and 'DataConstr'.
mkRdrName :: String -> RdrName
mkRdrName name@(x:_)
  -- ':' is special syntax. It is defined in module "GHC.Types" in
  -- package "ghc-prim", but not exported.
  | name == [':'] = nameRdrName consDataConName

  -- Data constructor starts from capital letter or ':'.
  | isUpper x || x == ':' = mkUnqual srcDataName (fsLit name)

  -- Variable.
  | otherwise = mkVarUnqual (fsLit name)

-- | Build 'HLocalBinds' from list of 'HDecl's.
declsToBinds :: Located a -> [HDecl] -> HLocalBinds
declsToBinds (L l _) decls = L l binds'
  where
    binds' = case decls of
      [] -> emptyLocalBinds
      _  -> HsValBinds (ValBindsIn (listToBag binds) sigs)
    (binds, sigs) = go ([],[]) decls
    go (bs,ss) ds =
      case ds of
        [] -> (bs, ss)
        d:ds' -> case d of
          L ld (ValD b) -> go (L ld b:bs,ss) ds'
          L ld (SigD s) -> go (bs,L ld s:ss) ds'

-- Function defined in 'HsUtils', not exported.
mkLocatedList ::  [Located a] -> Located [Located a]
mkLocatedList [] = noLoc []
mkLocatedList ms = L (combineLocs (head ms) (last ms)) ms

-- | Convert record field constructor expression to record field update
-- expression.
cfld2ufld :: Located (HsRecField RdrName (LHsExpr RdrName))
          -> Located (HsRecUpdField RdrName)
-- Almost same as 'mk_rec_upd_field' in 'RdrHsSyn'
cfld2ufld (L l0 (HsRecField (L l1 (FieldOcc rdr _)) arg pun)) =
  L l0 (HsRecField (L l1 (Unambiguous rdr PlaceHolder)) arg pun)

---
--- Builder functions
---

-- In GHC source code, there is a file "compiler/hsSyn/Convert.hs".
-- This module contains codes converting Template Haskell data types to
-- GHC's internal data type, which is a helpful resource for
-- understanding the values and types for constructing Haskell AST data.

b_module :: LTForm Atom -> Maybe LHsDocString -> [HImportDecl]
         -> [HDecl] -> HsModule RdrName
b_module (L l (TAtom (ASymbol name))) mbdoc imports decls =
    HsModule { hsmodName = Just (L l (mkModuleName name))
             , hsmodExports = Nothing
             , hsmodImports = imports
             -- Function `cvTopDecls' is used for mergeing multiple
             -- top-level FunBinds, which possibly taking different
             -- patterns in its arguments.
             , hsmodDecls = cvTopDecls (toOL decls)
             , hsmodDeprecMessage = Nothing
             , hsmodHaddockModHeader = mbdoc }


-- ------------
-- Declarations
-- ------------

b_importD :: LTForm Atom -> HImportDecl
b_importD (L l (TAtom (ASymbol m))) =
    L l (simpleImportDecl (mkModuleName m))

b_dataD :: Located a
        -> (String, [HTyVarBndr])
        -> (HsDeriving RdrName, [HConDecl])
        -> HDecl
b_dataD (L l _) (name, tvs) (derivs,cs) = L l (TyClD decl)
  where
    decl = DataDecl { tcdLName = L l (mkUnqual tcName (fsLit name))
                    , tcdTyVars = mkHsQTvs tvs
                    , tcdDataDefn = defn
                    , tcdDataCusk = PlaceHolder
                    , tcdFVs = placeHolderNames }
    defn = HsDataDefn { dd_ND = DataType
                      , dd_ctxt = noLoc []
                      , dd_cType = Nothing
                      , dd_kindSig = Nothing
                      , dd_cons = cs
                      -- `dd_derivs' field changed since ghc-8.0.2.
                      , dd_derivs = derivs }

b_simpletypeD :: [LTForm Atom] -> (String, [HTyVarBndr])
b_simpletypeD ((L _ (TAtom (ASymbol name))):tvs) = (name, tvs')
  -- XXX: Kind signatures not supported.
  where
    tvs' = map f tvs
    f (L l (TAtom (ASymbol tname))) =
        L l (UserTyVar (L l (mkUnqual tvName (fsLit tname))))

b_conD :: LTForm Atom -> HsConDeclDetails RdrName -> HConDecl
b_conD (L l1 (TAtom (ASymbol s1))) details =
    L l1 (ConDeclH98 { con_name = L l1 (mkUnqual srcDataName (fsLit s1))
                     , con_qvars = Nothing
                     , con_cxt = Nothing
                     , con_details = details
                     , con_doc = Nothing })

b_conOnlyD :: LTForm Atom -> HConDecl
b_conOnlyD name = b_conD name (PrefixCon [])

-- XXX: Infix data constructor not supported.
b_conDeclDetails :: [HType] -> HsConDeclDetails RdrName
b_conDeclDetails = PrefixCon

b_recFieldsD :: [HConDeclField] -> HsConDeclDetails RdrName
b_recFieldsD flds = RecCon (mkLocatedList flds)

b_recFieldD :: [LTForm Atom] -> HType -> HConDeclField
b_recFieldD names ty = L loc field
  where
    field = ConDeclField { cd_fld_names = names'
                         , cd_fld_type = ty
                         , cd_fld_doc = Nothing }
    loc = getLoc (mkLocatedList names)
    names' = map f names
    f (L l (TAtom (ASymbol name))) =
        L l (mkFieldOcc (L l (mkRdrName name)))

-- 'HsDeriving' changed in git head since ghc-8.0.2 release.
b_derivD :: (HsDeriving RdrName, [HConDecl])
         -> [HType]
         -> (HsDeriving RdrName, [HConDecl])
b_derivD (_, cs) tys = (Just (L l (map mkLHsSigType tys)), cs)
  where l = getLoc (mkLocatedList tys)

b_funD :: Located a -> (HExpr -> HsBind RdrName) -> HExpr -> HDecl
b_funD (L l _) f e = L l (ValD (f e))

b_declLhsB :: LTForm Atom -> [HPat] -> Builder (HExpr -> HsBind RdrName)
b_declLhsB (L l (TAtom (ASymbol name))) args =
    return (\body ->
              let match = mkMatch args body (L l emptyLocalBinds)
              in  mkFunBind (L l (mkRdrName name)) [match])

b_tsigD :: [LTForm Atom] -> HType -> HDecl
b_tsigD names typ =
  let typ' = mkLHsSigWcType typ
      mkName (L l (TAtom (ASymbol name))) = L l (mkRdrName name)
      l = getLoc (mkLocatedList names)
  in  L l (SigD (TypeSig (map mkName names) typ'))


-- -----
-- Types
-- -----

b_symT :: LTForm Atom -> HType
b_symT (L l (TAtom (ASymbol name))) = L l (HsTyVar (L l ty))
  where
    ty = mkUnqual namespace (fsLit name)
    namespace =
      case name of
        (x:_) | isUpper x || ':' == x -> tcName
        _ -> tvName

b_unitT :: LTForm Atom -> HType
b_unitT (L l _) = L l (HsTupleTy HsBoxedTuple [])

b_funT :: Located a -> HType -> HType -> HType
b_funT (L l _) a b = L l (HsFunTy a b)

b_appT :: [HType] -> HType
b_appT (x:xs) = foldl f x xs
  where f b a = L (getLoc b) (HsAppTy b a)

b_listT :: HType -> HType
b_listT ty@(L l _) = L l (HsListTy ty)

b_tupT :: Located a -> [HType] -> HType
b_tupT (L l _) ts = L l (HsTupleTy HsBoxedTuple ts)


-- -------
-- Pattern
-- -------

b_intP :: LTForm Atom -> HPat
b_intP (L l (TAtom (AInteger n))) = L l (mkNPat (L l lit) Nothing)
  where lit = mkHsIntegral (show n) n placeHolderType

b_stringP :: LTForm Atom -> HPat
b_stringP (L l (TAtom (AString s))) = L l (mkNPat (L l lit) Nothing)
  where lit = mkHsIsString s (fsLit s) placeHolderType

b_charP :: LTForm Atom -> HPat
b_charP (L l (TAtom (AChar c))) =
  let lit = HsChar (show c) c
  in  L l (LitPat lit)

b_symP :: LTForm Atom -> HPat
b_symP (L l (TAtom (ASymbol name@(x:_))))
   | name == "_" = L l (WildPat placeHolderType)
   | isUpper x || x == ':'
    = L l (ConPatIn (L l (mkRdrName name)) (PrefixCon []))
   | otherwise = L l (VarPat (L l (mkRdrName name)))

b_hsListP :: [HPat] -> HPat
b_hsListP pats = L l (ListPat pats placeHolderType Nothing)
  where l = getLoc (mkLocatedList pats)


b_tupP :: Located a -> [HPat] -> HPat
b_tupP (L l _) ps = L l (TuplePat ps Boxed [])

b_conP :: LTForm Atom -> [HPat] -> HPat
b_conP (L l (TAtom (ASymbol con))) rest =
    L l (ConPatIn (L l (mkRdrName con)) (PrefixCon rest))


-- ---------
-- Expression
-- ----------

b_ifE :: LTForm Atom -> HExpr -> HExpr -> HExpr -> HExpr
b_ifE (L l (TAtom _)) p t f = L l (mkHsIf p t f)

b_lamE ::  [HPat] -> HExpr -> HExpr
b_lamE pats body = mkHsLam pats body

b_tupE :: Located a -> [HExpr] -> HExpr
b_tupE (L l _) args = L l (ExplicitTuple (map mkArg args) Boxed)
  where mkArg x@(L al _) = L al (Present x)

b_letE :: Located a -> [HDecl] -> HExpr -> HExpr
b_letE ref@(L l _) decls body =
    L l (HsLet (declsToBinds ref decls) body)

b_caseE :: Located a -> HExpr -> [HMatch] -> HExpr
b_caseE (L l _) expr matches = L l (HsCase expr mg)
  where mg = mkMatchGroup FromSource matches

b_match :: HPat -> [HGRHS] -> HMatch
b_match pat@(L l _) grhss =
    L l (Match NonFunBindMatch [pat] Nothing grhss')
  where
    grhss' = GRHSs grhss (noLoc emptyLocalBinds)

b_hgrhs :: [HGRHS] -> (HExpr, [GuardLStmt RdrName]) -> [HGRHS]
b_hgrhs rhss (body, gs) =
  let rhs = GRHS gs body
      lrhs = case gs of
        [] -> noLoc rhs
        _  -> let l = getLoc (mkLocatedList gs) in L l rhs
  in  (lrhs:rhss)

b_grhs :: HExpr -> HExpr -> HGRHS
b_grhs guard@(L l _) body = L l (GRHS [L l (mkBodyStmt guard)] body)

b_doE :: Located a -> [HExprLStmt] -> HExpr
b_doE l exprs = L (getLoc l) (mkHsDo DoExpr exprs)

b_tsigE :: Located a -> HExpr -> HType -> HExpr
b_tsigE (L l _) e t = L l (ExprWithTySig e (mkLHsSigWcType t))

b_recConOrUpdE :: LTForm Atom -> [(String,HExpr)] -> HExpr
b_recConOrUpdE sym@(L l _) flds = L l expr
  where
    expr =
      case name of
        x:_ | isUpper x -> mkRdrRecordCon rName cflds
        _  -> mkRdrRecordUpd (b_varE sym) uflds
    name = symbolNameL sym
    rName = L l (mkRdrName name)
    cflds = HsRecFields { rec_flds = map mkcfld flds
                        , rec_dotdot = Nothing }
    uflds = map mkufld flds
    mkufld  = cfld2ufld . mkcfld

mkcfld :: (String,HExpr) -> LHsRecField RdrName HExpr
mkcfld (n,e@(L fl _)) =
  L fl (HsRecField { hsRecFieldLbl = mkfname fl n
                   , hsRecFieldArg = e
                   , hsRecPun = False })
  where
    mkfname fl n = L fl (mkFieldOcc (L fl (mkRdrName n)))

b_recUpdE :: Builder HExpr -> [(String,HExpr)] -> Builder HExpr
b_recUpdE expr flds = do
   expr' <- expr
   let uflds = map (cfld2ufld . mkcfld) flds
       l = getLoc expr'
   return (L l (mkRdrRecordUpd expr' uflds))

b_appE :: [HExpr] -> HExpr
b_appE = foldl1' (\a b -> L (getLoc a) (HsApp a b))

b_lbindB :: (HExpr -> HsBind RdrName) -> HExpr -> HBind
b_lbindB f e = L (getLoc e) (f e)

b_charE :: LTForm Atom -> HExpr
b_charE (L l (TAtom (AChar x))) = L l (HsLit (HsChar (show x) x))

b_stringE :: LTForm Atom -> HExpr
b_stringE (L l (TAtom (AString x))) = L l (HsLit (HsString x (fsLit x)))

b_integerE :: LTForm Atom -> HExpr
b_integerE (L l (TAtom (AInteger x))) =
    L l (HsOverLit $! (mkHsIntegral (show x) x placeHolderType))

b_floatE :: LTForm Atom -> HExpr
b_floatE (L l (TAtom (AFractional x))) =
   L l (HsOverLit $! (mkHsFractional x placeHolderType))

b_varE :: LTForm Atom -> HExpr
b_varE (L l (TAtom (ASymbol x))) = L l (HsVar (L l (mkRdrName x)))

b_unitE :: Located a -> HExpr
b_unitE (L l _) = L l (ExplicitTuple [] Boxed)

b_commentStringE :: LTForm Atom -> Located HsDocString
b_commentStringE (L l (TAtom (AComment x))) = L l (HsDocString (fsLit x))

b_hsListE :: [HExpr] -> HExpr
b_hsListE exprs = L l (ExplicitList placeHolderType Nothing exprs)
  where l = getLoc (mkLocatedList exprs)


-- ---------
-- Statement
-- ---------

b_bindS :: Located a -> HPat -> HExpr -> HExprLStmt
b_bindS ref pat expr = L (getLoc ref) (mkBindStmt pat expr)

b_letS :: Located a -> [HDecl] -> HExprLStmt
b_letS lref@(L l _) decls = L l (LetStmt (declsToBinds lref decls))

b_bodyS :: HExpr -> HExprLStmt
b_bodyS expr = L (getLoc expr) (mkBodyStmt expr)
