{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Dependent.Core.Parser where

import Control.Applicative ((<$>),(<*>),(*>),(<*))
import Control.Monad.Reader
import Data.List (foldl')
import Text.Parsec
import qualified Text.Parsec.Token as Token

import Abs
import Scope
import Dependent.Core.Abstraction
import Dependent.Core.ConSig
import Dependent.Core.Term
import Dependent.Core.Program




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
              , Token.reservedNames = ["data","case","motive","of","end","where","let","Type"]
              , Token.reservedOpNames = ["|","||","->","\\",":","::","=","."]
              , Token.caseSensitive = True
              }

tokenParser = Token.makeTokenParser languageDef

identifier = Token.identifier tokenParser
reserved = Token.reserved tokenParser
reservedOp = Token.reservedOp tokenParser
parens = Token.parens tokenParser





-- names

varName = do lookAhead (lower <|> char '_')
             identifier

decName = do lookAhead upper
             identifier


-- term parsers

variable = do x <- varName
              guard (x /= "_")
              return $ Var (Name x)

annotation = do m <- try $ do
                  m <- annLeft
                  _ <- reservedOp ":"
                  return m
                t <- annRight
                return $ Ann m t

typeType = do _ <- reserved "Type"
              return Type

binderFunType = do (xs,arg) <- try $ do
                     (xs,arg) <- parens $ do
                       xs <- many1 varName
                       _ <- reservedOp ":"
                       arg <- term
                       return (xs,arg)
                     _ <- reservedOp "->"
                     return (xs,arg)
                   ret <- funRet
                   return $ helperFold (\x -> funHelper x arg) xs ret

noBinderFunType = do arg <- try $ do
                       arg <- funArg
                       _ <- reservedOp "->"
                       return arg
                     ret <- funRet
                     return $ funHelper "_" arg ret

funType = binderFunType <|> noBinderFunType

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

assertionPattern = do _ <- reservedOp "."
                      m <- assertionPatternArg
                      return $ (AssertionPat m, [])

varPattern = do x <- varName
                return (VarPat x,[x])

noArgConPattern = do c <- decName
                     return $ (ConPat c PatternSeqNil, [])

conPattern = do c <- decName
                psxs <- many conPatternArg
                let (ps,xs) = patternSeqAndNames psxs
                return $ (ConPat c ps, xs)
  where
    patternSeqAndNames :: [(Pattern,[String])] -> (PatternSeq,[String])
    patternSeqAndNames []
      = (PatternSeqNil, [])
    patternSeqAndNames ((p,xs):psxs)
      = let (ps,xs') = patternSeqAndNames psxs
        in (patternSeqHelper p xs ps, xs++xs')

parenPattern = parens pattern

conPatternArg = assertionPattern <|> parenPattern <|> noArgConPattern <|> varPattern

assertionPatternArg = parenTerm <|> noArgConData <|> variable <|> typeType

pattern = assertionPattern <|> parenPattern <|> conPattern <|> varPattern

patternSeq = do psxs <- pattern `sepBy` reservedOp "||"
                return $ ( foldr (\(p,xs) ps -> patternSeqHelper p xs ps) PatternSeqNil psxs
                         , concat (map snd psxs)
                         )

consMotive = do (xs,a) <- try $ parens $ do
                  xs <- many1 varName
                  _ <- reservedOp ":"
                  a <- term
                  return (xs,a)
                _ <- reservedOp "||"
                b <- caseMotive
                return $ helperFold (\x -> consMotiveHelper x a) xs b

nilMotive = CaseMotiveNil <$> term

caseMotive = consMotive <|> nilMotive

clause = do (ps,xs) <- try $ do
              psxs <- patternSeq
              _ <- reservedOp "->"
              return psxs
            b <- term
            return $ clauseHelper ps xs b

caseExp = do _ <- reserved "case"
             ms <- caseArg `sepBy1` reservedOp "||"
             _ <- reservedOp "motive"
             mot <- caseMotive
             _ <- reserved "of"
             _ <- optional (reservedOp "|")
             cs <- clause `sepBy` reservedOp "|"
             _ <- reserved "end"
             return $ Case ms mot cs

parenTerm = parens term

annLeft = application <|> parenTerm <|> conData <|> variable <|> typeType

annRight = funType <|> application <|> parenTerm <|> lambda <|> conData <|> caseExp <|> variable <|> typeType

funArg = application <|> parenTerm <|> conData <|> caseExp <|> variable <|> typeType

funRet = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> conData <|> caseExp <|> variable <|> typeType

lamBody = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> conData <|> caseExp <|> variable <|> typeType

appFun = parenTerm <|> variable <|> typeType

appArg = parenTerm <|> noArgConData <|> variable <|> typeType

conArg = parenTerm <|> noArgConData <|> variable <|> typeType

caseArg = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> conData <|> variable <|> typeType

term = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> conData <|> caseExp <|> variable <|> typeType

parseTerm str = case parse (spaces *> term <* eof) "(unknown)" str of
                  Left e -> Left (show e)
                  Right p -> Right p



-- program parsers

termDecl = do _ <- reserved "let"
              x <- varName
              _ <- reservedOp ":"
              t <- term
              _ <- reservedOp "="
              m <- term
              _ <- reserved "end"
              return $ TermDeclaration x t m

alternative = do c <- decName
                 as <- alternativeArgs
                 _ <- reservedOp ":"
                 t <- term
                 return (c,conSigHelper as t)

alternativeArgs = do argss <- many alternativeArg
                     return (concat argss)

alternativeArg = parens $ do
                   xs <- many1 varName
                   _ <- reservedOp ":"
                   t <- term
                   return $ [ DeclArg x t | x <- xs ]

emptyTypeDecl = do (tycon,tyargs) <- try $ do
                     _ <- reserved "data"
                     tycon <- decName
                     tyargs <- many typeArg
                     _ <- reserved "end"
                     return (tycon,tyargs)
                   return $ TypeDeclaration tycon tyargs []

nonEmptyTypeDecl = do (tycon,tyargs) <- try $ do
                        _ <- reserved "data"
                        tycon <- decName
                        tyargs <- many typeArg
                        _ <- reserved "where"
                        return (tycon,tyargs)
                      _ <- optional (reservedOp "|")
                      alts <- alternative `sepBy` reservedOp "|"
                      _ <- reserved "end"
                      return $ TypeDeclaration tycon tyargs alts

typeArg = parens $ do
            x <- varName
            _ <- reservedOp ":"
            t <- term
            return $ DeclArg x t

typeDecl = emptyTypeDecl <|> nonEmptyTypeDecl

statement = TmDecl <$> termDecl
        <|> TyDecl <$> typeDecl

program = Program <$> many statement



parseProgram :: String -> Either String Program
parseProgram str
  = case parse (spaces *> program <* eof) "(unknown)" str of
      Left e -> Left (show e)
      Right p -> Right p