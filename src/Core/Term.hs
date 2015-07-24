module Core.Term where

import Data.List (intercalate)

import Core.Type

data Term
  = Var String
  | Ann Term Type
  | Lam String Term
  | App Term Term
  | Con String [Term]
  | Case Term [Clause]

data TermParenLoc = RootTerm | AnnLeft | LamBody | AppLeft | AppRight | ConArg | CaseArg
  deriving (Eq)

instance Show Term where
  show t = aux RootTerm t
    where
      aux c t
        = let (cs, str) = case t of
                Var x     -> ([RootTerm,AnnLeft,LamBody,AppLeft,AppRight,ConArg,CaseArg], x)
                Ann m t   -> ([RootTerm,LamBody,ConArg,CaseArg], aux AnnLeft m ++ " : " ++ show t)
                Lam x b   -> ([RootTerm,LamBody,ConArg,CaseArg], "\\" ++ x ++ " -> " ++ aux LamBody b)
                App f a   -> ([RootTerm,AnnLeft,LamBody,AppLeft,ConArg,CaseArg], aux AppLeft f ++ " " ++ aux AppRight a)
                Con c as  -> ([RootTerm,AnnLeft,LamBody,AppLeft,ConArg,CaseArg], c ++ "(" ++ intercalate "," (map (aux ConArg) as) ++ ")")
                Case m cs -> ([RootTerm,LamBody,ConArg], "case " ++ aux CaseArg m ++ " of " ++ intercalate " | " (map show cs) ++ " end")
          in if c `elem` cs
             then str
             else "(" ++ str ++ ")"

data Clause
  = Clause Pattern Term

instance Show Clause where
  show (Clause p t) = show p ++ " -> " ++ show t


data Pattern
  = VarPat String
  | ConPat String [Pattern]

instance Show Pattern where
  show (VarPat x) = x
  show (ConPat c as) = c ++ "(" ++ intercalate "," (map show as) ++ ")"