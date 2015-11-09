{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Poly.Core.Parser where

import Control.Applicative ((<$>),(*>),(<*),(<*>))
import Control.Monad.Reader
import Data.List (foldl')
import Text.Parsec
import qualified Text.Parsec.Token as Token

import Abs
import Scope
import Poly.Core.Term
import Poly.Core.Type
import Poly.Core.Program




-- Abstraction

abstractClause :: Clause -> Abstracted String Term Clause
abstractClause (Clause p sc)
  = Clause p <$> abstractScope sc

instance Abstract String Term Term where
  abstract (Var (Name x))
    = reader $ \e ->
        case lookup x e of
          Nothing -> Var (Name x)
          Just m  -> m
  abstract (Var (Generated i))
    = return $ Var (Generated i)
  abstract (Ann m ty)
    = Ann <$> abstract m <*> return ty
  abstract (Lam sc)
    = Lam <$> abstractScope sc
  abstract (App f a)
    = App <$> abstract f <*> abstract a
  abstract (Con c as)
    = Con c <$> mapM abstract as
  abstract (Case a cs)
    = Case <$> mapM abstract a <*> mapM abstractClause cs

lamHelper :: String -> Term -> Term
lamHelper x b = Lam (scope [x] b)

clauseHelper :: [Pattern] -> [String] -> Term -> Clause
clauseHelper ps xs b = Clause ps (scope xs b)

instance Abstract String Type Type where
  abstract (Meta i)
    = return $ Meta i
  abstract (TyVar (TyName x))
    = reader $ \e ->
        case lookup x e of
          Nothing -> TyVar (TyName x)
          Just m  -> m
  abstract (TyVar (TyGenerated i))
    = return $ TyVar (TyGenerated i)
  abstract (TyCon c as)
    = TyCon c <$> mapM abstract as
  abstract (Fun a b)
    = Fun <$> abstract a <*> abstract b
  abstract (Forall sc)
    = Forall <$> abstractScope sc

forallHelper :: String -> Type -> Type
forallHelper x b = Forall (scope [x] b)




-- Language Definition

languageDef :: Token.LanguageDef st
languageDef = Token.LanguageDef
              { Token.commentStart = "{-"
              , Token.commentEnd = "-}"
              , Token.commentLine = "--"
              , Token.nestedComments = True
              , Token.identStart = letter <|> char '_'
              , Token.identLetter = alphaNum <|> char '_' <|> char '\''
              , Token.opStart = oneOf ""
              , Token.opLetter = oneOf ""
              , Token.reservedNames = ["data","case","of","end","where","let","forall"]
              , Token.reservedOpNames = ["|","->","\\",":","=",".","||"]
              , Token.caseSensitive = True
              }

tokenParser = Token.makeTokenParser languageDef

identifier = Token.identifier tokenParser
reserved = Token.reserved tokenParser
reservedOp = Token.reservedOp tokenParser
parens = Token.parens tokenParser
symbol = Token.symbol tokenParser





-- names

varName = do lookAhead (lower <|> char '_')
             identifier

decName = do lookAhead upper
             identifier


-- type parsers

noArgTypeCon = do c <- decName
                  return $ TyCon c []

typeCon = TyCon <$> decName <*> many tyConArg

funType = do arg <- try $ do
               arg <- funLeft
               _ <- reservedOp "->"
               return arg
             ret <- funRight
             return $ Fun arg ret

typeVar = do x <- varName
             guard (x /= "_")
             return $ TyVar (TyName x)

forallType = do _ <- reserved "forall"
                xs <- many1 varName
                _ <- reservedOp "."
                b <- forallBody
                return $ helperFold forallHelper xs b

parenType = parens datatype

tyConArg = parenType <|> noArgTypeCon <|> typeVar

funLeft = parenType <|> typeCon <|> typeVar

funRight = funType <|> parenType <|> forallType <|> typeCon <|> typeVar

forallBody = funType <|> parenType <|> forallType <|> typeCon <|> typeVar

datatype = funType <|> parenType <|> forallType <|> typeCon <|> typeVar



-- term parsers

variable = do x <- varName
              guard (x /= "_")
              return $ Var (Name x)

annotation = do m <- try $ do
                  m <- annLeft
                  _ <- reservedOp ":"
                  return m
                t <- datatype
                return $ Ann m t

lambda = do _ <- reservedOp "\\"
            xs <- many1 varName
            _ <- reservedOp "->"
            b <- lamBody
            return $ helperFold lamHelper xs b

application = do (f,a) <- try $ do
                   f <- appFun
                   a <- appArg
                   return (f,a)
                 as <- many appArg
                 return $ foldl' App f (a:as)

noArgConData = do c <- decName
                  return $ Con c []

conData = do c <- decName
             as <- many conArg
             return $ Con c as

varPattern = do x <- varName
                return (VarPat x,[x])

noArgConPattern = do c <- decName
                     return $ (ConPat c [], [])

conPattern = do c <- decName
                psxs <- many conPatternArg
                let (ps,xs) = unzip psxs
                return $ (ConPat c ps, concat xs)

parenPattern = parens pattern

conPatternArg = parenPattern <|> noArgConPattern <|> varPattern

pattern = parenPattern <|> conPattern <|> varPattern

clause = do psxs <- try $ do
              psxs <- pattern `sepBy` reservedOp "||"
              _ <- reservedOp "->"
              return psxs
            b <- term
            let ps = map fst psxs
                xs = concat (map snd psxs)
            return $ clauseHelper ps xs b

caseExp = do _ <- reserved "case"
             m <- caseArg `sepBy` reservedOp "||"
             _ <- reserved "of"
             _ <- optional (reservedOp "|")
             cs <- clause `sepBy` reservedOp "|"
             _ <- reserved "end"
             return $ Case m cs

parenTerm = parens term

annLeft = application <|> parenTerm <|> conData <|> variable

lamBody = annotation <|> application <|> parenTerm <|> lambda <|> conData <|> caseExp <|> variable

appFun = parenTerm <|> variable

appArg = parenTerm <|> noArgConData <|> variable

conArg = parenTerm <|> noArgConData <|> variable

caseArg = annotation <|> application <|> parenTerm <|> lambda <|> conData <|> variable

term = annotation <|> application <|> parenTerm <|> lambda <|> conData <|> caseExp <|> variable

parseTerm str = case parse (spaces *> term <* eof) "(unknown)" str of
                  Left e -> Left (show e)
                  Right p -> Right p



-- program parsers

eqTermDecl = do (x,t) <- try $ do
                  _ <- reserved "let"
                  x <- varName
                  _ <- reservedOp ":"
                  t <- datatype
                  _ <- reservedOp "="
                  return (x,t)
                m <- term
                _ <- reserved "end"
                return $ TermDeclaration x t m

whereTermDecl = do (x,t) <- try $ do
                     _ <- reserved "let"
                     x <- varName
                     _ <- reservedOp ":"
                     t <- datatype
                     _ <- reserved "where"
                     return (x,t)
                   _ <- optional (reservedOp "|")
                   clauses@(Clause ps _:_) <- patternMatchClause x `sepBy1` reservedOp "|"
                   _ <- reserved "end"
                   return $ TermDeclaration x t (lambdaAux (\as -> Case as clauses) (length ps))
  where
    lambdaAux :: ([Term] -> Term) -> Int -> Term
    lambdaAux f 0 = f []
    lambdaAux f n = Lam (Scope ["_" ++ show n] $ \[x] -> lambdaAux (f . (x:)) (n-1))

patternMatchClause x = do _ <- symbol x
                          psxs <- many patternMatchPattern
                          _ <- reservedOp "="
                          b <- term
                          let ps = map fst psxs
                              xs = concat (map snd psxs)
                          return $ clauseHelper ps xs b

patternMatchPattern = parenPattern <|> noArgConPattern <|> varPattern

termDecl = eqTermDecl <|> whereTermDecl

alternative = do c <- decName
                 as <- many alternativeArg
                 return (c,as)

alternativeArg = parenType <|> typeCon <|> typeVar

typeDecl = do _ <- reserved "data"
              tycon <- decName
              params <- many varName
              alts <- option [] $ do
                _ <- reservedOp "="
                alternative `sepBy` reservedOp "|"
              _ <- reserved "end"
              return $ TypeDeclaration tycon params alts

statement = TmDecl <$> termDecl
        <|> TyDecl <$> typeDecl

program = Program <$> many statement



parseProgram :: String -> Either String Program
parseProgram str
  = case parse (spaces *> program <* eof) "(unknown)" str of
      Left e -> Left (show e)
      Right p -> Right p