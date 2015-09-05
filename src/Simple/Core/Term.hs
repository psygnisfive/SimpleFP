{-# OPTIONS -Wall #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Simple.Core.Term where

import Control.Monad.State
import Data.List (intercalate)

import Parens
import Simple.Core.Type



-- Terms

data Variable
  = Name String
  | Generated Int

data Scope
  = Scope { instantiate :: [Term] -> Term }

data Term
  = Var Variable
  | Ann Term Type
  | Lam Scope
  | App Term Term
  | Con String [Term]
  | Case Term [Clause]

data Clause
  = Clause Pattern Scope

data Pattern
  = VarPat
  | ConPat String [Pattern]



-- Show Instances

instance Show Variable where
  show (Name x) = x
  show (Generated i) = "$" ++ show i

next :: State Int Int
next = do i <- get
          put (i+1)
          return i

data PatternParenLoc = RootPattern | ConPatArg
  deriving (Eq)

instance ParenLoc Pattern where
  type Loc Pattern = PatternParenLoc
  parenLoc VarPat        = [RootPattern,ConPatArg]
  parenLoc (ConPat _ []) = [RootPattern,ConPatArg]
  parenLoc (ConPat _ _)  = [RootPattern]

instance ParenBound (State Int) Pattern where
  parenBound VarPat
    = do i <- next
         return (show (Generated i),[i])
  parenBound (ConPat c [])
    = return (c,[])
  parenBound (ConPat c ps)
    = do r <- mapM (parenthesizeBound (Just ConPatArg)) ps
         let (ps',xs) = unzip r
         return (c ++ " " ++ intercalate " " ps', concat xs)


data TermParenLoc = RootTerm | AnnLeft | LamBody | AppLeft | AppRight | ConArg | CaseArg
  deriving (Eq)

instance ParenLoc Term where
  type Loc Term = TermParenLoc
  parenLoc (Var _)
    = [RootTerm,AnnLeft,LamBody,AppLeft,AppRight,ConArg,CaseArg]
  parenLoc (Ann _ _)
    = [RootTerm,LamBody,CaseArg]
  parenLoc (Lam _)
    = [RootTerm,LamBody,CaseArg]
  parenLoc (App _ _)
    = [RootTerm,AnnLeft,LamBody,AppLeft,CaseArg]
  parenLoc (Con _ [])
    = [RootTerm,AnnLeft,LamBody,AppLeft,AppRight,ConArg,CaseArg]
  parenLoc (Con _ _)
    = [RootTerm,AnnLeft,LamBody,CaseArg]
  parenLoc (Case _ _)
    = [RootTerm,LamBody]

instance ParenRec (State Int) Term where
  parenRec (Var (Name x))
    = return x
  parenRec (Var (Generated i))
    = return $ "_" ++ show i
  parenRec (Ann m t)
    = do m' <- parenthesize (Just AnnLeft) m
         return $ m' ++ " : " ++ show t
  parenRec (Lam sc)
    = do i <- next
         b' <- parenthesize (Just LamBody) (instantiate sc [Var (Generated i)])
         return $ "\\" ++ show i ++ " -> " ++ b'
  parenRec (App f a)
    = do f' <- parenthesize (Just AppLeft) f
         a' <- parenthesize (Just AppRight) a
         return $ f' ++ " " ++ a'
  parenRec (Con c [])
    = return c
  parenRec (Con c as)
    = do as' <- mapM (parenthesize (Just ConArg)) as
         return $ c ++ " " ++ intercalate " " as'
  parenRec (Case a cs)
    = do a' <- parenthesize (Just CaseArg) a
         cs' <- mapM auxClause cs
         return $ "case " ++ a' ++ " of " ++ intercalate " | " cs' ++ "end"
    where
      auxClause (Clause p sc)
        = do (pat,is) <- parenthesizeBound Nothing p
             b <- parenthesize Nothing (instantiate sc (map (Var . Generated) is))
             return $ pat ++ " -> " ++ b

instance Show Term where
  show t = fst (runState (parenRec t) (0 :: Int))