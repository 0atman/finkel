{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
-- | Data type for form, take 3.

module SK.Core.Form
  ( Form(..)
  , Atom(..)
  , TForm(..)
  , LTForm
  , Code(..)
  , splice
  , lTFormToForm
  , nlForm
  , fTail
  , fHead
  , pprForm
  , pprForms
  , pprTForm
  , pprTForms
  , pForm
  , pForms
  , pAtom
  ) where

-- From base
import Data.Data

-- Pretty module from ghc.
import qualified Pretty as P

-- Internal
import SK.Core.GHC

---
--- Form data type
---

-- | Simple form type.
data Form a
  = Atom a
  | List [Form a]
  deriving (Eq, Show, Data, Typeable)

-- | Atom in tokens.
data Atom
  = AUnit
  | ASymbol String
  | AString String
  | AInteger Integer
  | AComment String
  deriving (Eq, Show, Data, Typeable)

-- | Token form. Contains location information.
data TForm a
  = TAtom a            -- ^ S-expression atom.
  | TList [LTForm a]   -- ^ S-expression list.
  | THsList [LTForm a] -- ^ Haskell list.
  | TEnd               -- ^ End of token.
  deriving (Eq, Data, Typeable)

instance Show a => Show (TForm a) where
  show (TAtom a) = "TAtom " ++ show a
  show (TList as) = "TList " ++ show (map unLoc as)
  show (THsList as) = "THsList " ++ show (map unLoc as)
  show TEnd = "TEnd"

type LTForm a = Located (TForm a)

-- | Converts located token form to bare 'Form'. Location information,
-- token end constructor, and Haskell list constructor disappears.
lTFormToForm :: LTForm a -> Form a
lTFormToForm form =
   case unLoc form of
     TAtom a    -> Atom a
     TList xs   -> List (map lTFormToForm xs)
     THsList xs -> List (map lTFormToForm xs)
     TEnd       -> Atom undefined

-- | Make a token form with no location information.
nlForm :: Form a -> LTForm a
nlForm form =
  case form of
    Atom x -> noLoc (TAtom x)
    List xs -> noLoc (TList (map nlForm xs))

fTail :: LTForm a -> LTForm a
fTail (L l (TList (_:xs))) = L l (TList xs)
fTail _ = error "fTail"

fHead :: LTForm a -> LTForm a
fHead (L l (TList (x:_))) = x
fHead _ = error "fHead"

pprForm :: Form Atom -> P.Doc
pprForm form =
  case form of
    Atom x -> P.text "Atom" P.<+> P.parens (pprAtom x)
    List xs -> P.text "List" P.<+> P.nest 2 (pprForms xs)

pprForms :: [Form Atom] -> P.Doc
pprForms forms =
  P.brackets (P.sep (P.punctuate P.comma (map pprForm forms)))

pprAtom :: Atom -> P.Doc
pprAtom atom =
  case atom of
    AUnit     -> P.text "AUnit"
    ASymbol x -> P.text "ASymbol" P.<+> P.text x
    AString x -> P.text "AString" P.<+> P.doubleQuotes (P.text x)
    AInteger x -> P.text "AInteger" P.<+> (P.text (show x))
    AComment x -> P.text "AComment" P.<+> (P.doubleQuotes (P.text x))

pprTForm :: LTForm Atom -> P.Doc
pprTForm (L _ form) =
  case form of
    TAtom x -> P.text "TAtom" P.<+> P.parens (pprAtom x)
    TList xs -> P.text "TList" P.<+> P.nest 2 (pprTForms xs)
    THsList xs -> P.text "THsList" P.<+> P.nest 2 (pprTForms xs)
    TEnd -> P.text "TEnd"

pprTForms :: [LTForm Atom] -> P.Doc
pprTForms forms =
  P.brackets (P.sep (P.punctuate P.comma (map pprTForm forms)))

pForm :: Form Atom -> P.Doc
pForm form =
  case form of
    Atom a -> pAtom a
    List forms -> pForms forms

pForms :: [Form Atom] -> P.Doc
pForms forms =
  case forms of
    [] -> P.empty
    _  -> P.parens (P.sep (map pForm forms))

pAtom :: Atom -> P.Doc
pAtom atom =
  case atom of
    ASymbol x -> P.text x
    AString x -> P.doubleQuotes (P.text x)
    AInteger x -> P.text (show x)
    AUnit -> P.text "()"
    AComment _ -> P.empty

--- -------------------
--- Code type class

--- Instance data types of Formable class could be inserted to
--- S-expression form with `unquote' and `unquote-splice'.

class Code a where
  toForm :: a -> Form Atom
  fromForm :: Form Atom -> Maybe a
  fromForm _ = Nothing

instance Code Atom where
  toForm a = Atom a
  fromForm a =
    case a of
      Atom x -> Just x
      _      -> Nothing

instance Code () where
  toForm _ = Atom AUnit
  fromForm a =
    case a of
      Atom AUnit -> Just ()
      _          -> Nothing

instance Code Int where
  toForm a = Atom (AInteger (fromIntegral a))
  fromForm a =
    case a of
      Atom (AInteger n) -> Just (fromIntegral n)
      _                 -> Nothing

instance Code Integer where
  toForm a = Atom (AInteger a)
  fromForm a =
    case a of
      Atom (AInteger n) -> Just n
      _                 -> Nothing

instance Code Char where
  -- Need another constructor for Char in Atom.
  toForm = undefined
  fromForm = undefined

instance Code String where
  toForm a = Atom (AString a)
  fromForm a =
    case a of
      Atom (AString s) -> Just s
      _                -> Nothing

instance Code a => Code (Form a) where
  toForm form =
    case form of
      Atom a  -> toForm a
      List as -> List (map toForm as)
  fromForm a =
    case a of
      Atom _  -> fromForm a
      List as -> List <$> mapM fromForm as

splice :: Code a => a -> [Form Atom]
splice form =
  case toForm form of
    List xs -> xs
    _       -> []
