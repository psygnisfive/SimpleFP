{-# OPTIONS -Wall #-}
{-# LANGUAGE TypeFamilies #-}

module Simple.Core.Type where

import Parens



-- Types

data Type
  = TyCon String
  | Fun Type Type
  | Meta Int
  deriving (Eq)



-- Show Instance

data TypeParenLoc = FunLeft | FunRight
  deriving (Eq)

instance ParenLoc Type where
  type Loc Type = TypeParenLoc
  parenLoc (TyCon _) = [FunLeft,FunRight]
  parenLoc (Fun _ _) = [FunRight]
  parenLoc (Meta _)  = [FunLeft,FunRight]

instance ParenRec Type where
  parenRec (TyCon c) = c
  parenRec (Fun a b) = parenthesize (Just FunLeft) a
                    ++ " -> "
                    ++ parenthesize (Just FunRight) b
  parenRec (Meta i)  = "?" ++ show i

instance Show Type where
  show t = parenthesize Nothing t