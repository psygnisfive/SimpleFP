{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Modular.Core.Parser where

import Control.Applicative ((<$>),(<*>),(*>),(<*))
import Control.Monad.Reader
import Data.List (foldl')
import Text.Parsec
import qualified Text.Parsec.Token as Token

import Abs
import Plicity
import Scope
import Modular.Core.Abstraction
import Modular.Core.ConSig
import Modular.Core.Term
import Modular.Core.Program




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
              , Token.reservedNames = ["data","case","motive","of","end","where"
                                      ,"let","Type","module","open","opening"
                                      ,"as","using","hiding","renaming","to","in"]
              , Token.reservedOpNames = ["|","||","->","\\",":","::","=",".",","]
              , Token.caseSensitive = True
              }

tokenParser = Token.makeTokenParser languageDef

identifier = Token.identifier tokenParser
reserved = Token.reserved tokenParser
reservedOp = Token.reservedOp tokenParser
parens = Token.parens tokenParser
braces = Token.braces tokenParser
symbol = Token.symbol tokenParser





-- names

varName = do lookAhead (lower <|> char '_')
             identifier

decName = do lookAhead upper
             identifier


-- open settings

oAs = optionMaybe $ do
        _ <- reserved "as"
        decName

oHidingUsing = optionMaybe (hiding <|> using)
  where
    hiding = do _ <- reserved "hiding"
                ns <- parens (sepBy (varName <|> decName) (reservedOp ","))
                return (Hiding ns)
    using = do _ <- reserved "using"
               ns <- parens (sepBy (varName <|> decName) (reservedOp ","))
               return (Using ns)

oRenaming = do m <- openRenamingP
               case m of
                 Nothing -> return []
                 Just ns -> return ns
  where
    openRenamingP = optionMaybe $ do
                      _ <- reserved "renaming"
                      parens (sepBy (varRen <|> decRen) (reservedOp ","))
    varRen = do n <- varName
                _ <- reserved "to"
                n' <- varName
                return (n,n')
    decRen = do n <- decName
                _ <- reserved "to"
                n' <- decName
                return (n,n')

openSettings = OpenSettings <$> decName
                            <*> oAs
                            <*> oHidingUsing
                            <*> oRenaming


-- term parsers

variable = do x <- varName
              guard (x /= "_")
              return $ Var (Name x)

dottedVar = try $ do
              modName <- decName
              _ <- reservedOp "."
              valName <- varName
              return $ DottedVar modName valName

annotation = do m <- try $ do
                  m <- annLeft
                  _ <- reservedOp ":"
                  return m
                t <- annRight
                return $ Ann m t

typeType = do _ <- reserved "Type"
              return Type

explFunType = do (xs,arg) <- try $ do
                   (xs,arg) <- parens $ do
                     xs <- many1 varName
                     _ <- reservedOp ":"
                     arg <- term
                     return (xs,arg)
                   _ <- reservedOp "->"
                   return (xs,arg)
                 ret <- funRet
                 return $ helperFold (\x -> funHelper Expl x arg) xs ret

implFunType = do (xs,arg) <- try $ do
                   (xs,arg) <- braces $ do
                     xs <- many1 varName
                     _ <- reservedOp ":"
                     arg <- term
                     return (xs,arg)
                   _ <- reservedOp "->"
                   return (xs,arg)
                 ret <- funRet
                 return $ helperFold (\x -> funHelper Impl x arg) xs ret

binderFunType = explFunType <|> implFunType

noBinderFunType = do arg <- try $ do
                       arg <- funArg
                       _ <- reservedOp "->"
                       return arg
                     ret <- funRet
                     return $ funHelper Expl "_" arg ret

funType = binderFunType <|> noBinderFunType

explArg = do x <- varName
             return (Expl,x)

implArg = do x <- braces varName
             return (Impl,x)

lambdaArg = explArg <|> implArg

lambda = do xs <- try $ do
              _ <- reservedOp "\\"
              many1 lambdaArg
            _ <- reservedOp "->"
            b <- lamBody
            return $ helperFold (\(plic,x) -> lamHelper plic x) xs b

application = do (f,pa) <- try $ do
                   f <- appFun
                   pa <- appArg
                   return (f,pa)
                 pas <- many appArg
                 return $ foldl' (\f' (plic,a') -> App plic f' a') f (pa:pas)

bareCon = BareCon <$> decName

dottedCon = try $ do
              modName <- decName
              _ <- reservedOp "."
              conName <- decName
              return $ DottedCon modName conName

constructor = dottedCon <|> bareCon

noArgConData = do c <- constructor
                  return $ Con c []

conData = do c <- constructor
             as <- many conArg
             return $ Con c as

assertionPattern = do _ <- reservedOp "."
                      m <- assertionPatternArg
                      return $ (AssertionPat m, [])

varPattern = do x <- varName
                return (VarPat (Name x),[x])

noArgConPattern = do c <- constructor
                     return $ (ConPat c [], [])

conPattern = do c <- constructor
                psxs <- many conPatternArg
                let (ps,xss) = unzip psxs
                return $ (ConPat c ps, concat xss)

parenPattern = parens pattern

rawExplConPatternArg = assertionPattern <|> parenPattern <|> noArgConPattern <|> varPattern

explConPatternArg = do (p,xs) <- rawExplConPatternArg
                       return ((Expl,p),xs)

rawImplConPatternArg = assertionPattern <|> parenPattern <|> conPattern <|> varPattern

implConPatternArg = do (p,xs) <- braces $ rawImplConPatternArg
                       return ((Impl,p),xs)

conPatternArg = explConPatternArg <|> implConPatternArg

assertionPatternArg = parenTerm <|> noArgConData <|> variable <|> typeType

pattern = assertionPattern <|> parenPattern <|> conPattern <|> varPattern

patternSeq = do psxs <- pattern `sepBy` reservedOp "||"
                let (ps,xss) = unzip psxs
                return (ps,concat xss)

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

openExp = do _ <- reserved "open"
             _ <- optional (reserved "|")
             settings <- sepBy openSettings (reserved "|")
             _ <- reserved "in"
             m <- term
             _ <- reserved "end"
             return (OpenIn settings m)

parenTerm = parens term

annLeft = application <|> parenTerm <|> dottedVar <|> conData <|> variable <|> typeType

annRight = funType <|> application <|> parenTerm <|> lambda <|> dottedVar <|> conData <|> caseExp <|> variable <|> typeType

funArg = application <|> parenTerm <|> dottedVar <|> conData <|> caseExp <|> variable <|> typeType <|> openExp

funRet = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> dottedVar <|> conData <|> caseExp <|> variable <|> typeType <|> openExp

lamBody = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> dottedVar <|> conData <|> caseExp <|> variable <|> typeType <|> openExp

appFun = parenTerm <|> variable <|> dottedVar <|> typeType

rawExplAppArg = parenTerm <|> dottedVar <|> noArgConData <|> variable <|> typeType

explAppArg = do m <- rawExplAppArg
                return (Expl,m)

rawImplAppArg = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> dottedVar <|> conData <|> caseExp <|> variable <|> typeType <|> openExp

implAppArg = do m <- braces $ rawImplAppArg
                return (Impl,m)

appArg = explAppArg <|> implAppArg

rawExplConArg = parenTerm <|> dottedVar <|> noArgConData <|> variable <|> typeType

explConArg = do m <- rawExplConArg
                return (Expl,m)

rawImplConArg = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> dottedVar <|> conData <|> caseExp <|> variable <|> typeType <|> openExp

implConArg = do m <- braces $ rawImplConArg
                return (Impl,m)

conArg = explConArg <|> implConArg

caseArg = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> dottedVar <|> conData <|> variable <|> typeType

term = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> dottedVar <|> conData <|> caseExp <|> variable <|> typeType <|> openExp

parseTerm str = case parse (spaces *> term <* eof) "(unknown)" str of
                  Left e -> Left (show e)
                  Right p -> Right p



-- program parsers

eqTermDecl = do (x,t) <- try $ do
                  _ <- reserved "let"
                  x <- varName
                  _ <- reservedOp ":"
                  t <- term
                  _ <- reservedOp "="
                  return (x,t)
                m <- term
                _ <- reserved "end"
                return $ TermDeclaration x t m

whereTermDecl = do (x,t) <- try $ do
                     _ <- reserved "let"
                     x <- varName
                     _ <- reservedOp ":"
                     t <- term
                     _ <- reserved "where"
                     return (x,t)
                   _ <- optional (reservedOp "|")
                   --plicsClauses@((_,Clause ps _):_) <- patternMatchClause x `sepBy1` reservedOp "|"
                   preclauses <- patternMatchClause x `sepBy1` reservedOp "|"
                   _ <- reserved "end"
                   case preclauses of
                     [(plics,(ps,xs,b))] | all isVar ps
                       -> return $ TermDeclaration x t (helperFold (uncurry lamHelper) (zip plics xs) b)
                     (_,(ps0,_,_)):_
                       -> do let lps0 = length ps0
                             unless (all (\(_,(ps,_,_)) -> length ps == lps0) preclauses)
                               $ fail "Mismatching number of patterns in different clauses of a pattern matching function."
                             let (plics:plicss) = map fst preclauses
                             unless (all (plics==) plicss)
                               $ fail "Mismatching plicities in different clauses of a pattern matching function"
                             case truePlicities plics t of
                               Nothing
                                 -> fail $ "Cannot build a case expression motive from the type " ++ show t
                               Just truePlics
                                 -> do let mot = motiveAux (length truePlics) t
                                           clauses = [ clauseHelper (truePatterns truePlics ps) xs b | (_,(ps,xs,b)) <- preclauses ]
                                           plicsForLambdaAux = map (either id id) truePlics
                                       return $ TermDeclaration x t (lambdaAux (\as -> Case as mot clauses) plicsForLambdaAux)
  where
    isVar :: Pattern -> Bool
    isVar (VarPat _) = True
    isVar _ = False
    
    lambdaAux :: ([Term] -> Term) -> [Plicity] -> Term
    lambdaAux f [] = f []
    lambdaAux f (plic:plics) = Lam plic (Scope ["_" ++ show (length plics)] $ \[x] -> lambdaAux (f . (x:)) plics)
    
    truePlicities :: [Plicity] -> Term -> Maybe [Either Plicity Plicity]
    truePlicities [] _ = Just []
    truePlicities (Expl:plics) (Fun Expl _ sc)
      = do rest <- truePlicities plics (descope (Var . Name) sc)
           return $ Right Expl : rest
    truePlicities (Expl:plics) (Fun Impl _ sc)
      = do rest <- truePlicities (Expl : plics) (descope (Var . Name) sc)
           return $ Left Impl : rest
    truePlicities (Impl:plics) (Fun Expl _ sc)
      = Nothing
    truePlicities (Impl:plics) (Fun Impl _ sc)
      = do rest <- truePlicities plics (descope (Var . Name) sc)
           return $ Right Impl : rest
    
    motiveAux :: Int -> Term -> CaseMotive
    motiveAux 0 t = CaseMotiveNil t
    motiveAux n (Fun _ a (Scope ns b)) = CaseMotiveCons a (Scope ns (motiveAux (n-1) . b))
    
    truePatterns :: [Either Plicity Plicity] -> [Pattern] -> [Pattern]
    truePatterns [] [] = []
    truePatterns (Right _:plics) (p:ps)
      = p : truePatterns plics ps
    truePatterns (Left _:plics) ps
      = MakeMeta : truePatterns plics ps


patternMatchClause x = do _ <- symbol x
                          (ps,xs) <- wherePatternSeq
                          _ <- reservedOp "="
                          b <- term
                          return $ (map fst ps, (map snd ps,xs,b))

rawExplWherePattern = assertionPattern <|> parenPattern <|> noArgConPattern <|> varPattern

explWherePattern = do (p,xs) <- rawExplWherePattern
                      return ((Expl,p),xs)

rawImplWherePattern = assertionPattern <|> parenPattern <|> conPattern <|> varPattern

implWherePattern = do (p,xs) <- braces $ rawImplWherePattern
                      return ((Impl,p),xs)

wherePattern = implWherePattern <|> explWherePattern

wherePatternSeq = do psxs <- many wherePattern
                     let (ps,xss) = unzip psxs
                     return (ps,concat xss)

termDecl = eqTermDecl <|> whereTermDecl

alternative = do c <- decName
                 as <- alternativeArgs
                 _ <- reservedOp ":"
                 t <- term
                 return (c,conSigHelper as t)

explAlternativeArg = parens $ do
                       xs <- many1 varName
                       _ <- reservedOp ":"
                       t <- term
                       return $ [ DeclArg Expl x t | x <- xs ]

implAlternativeArg = braces $ do
                       xs <- many1 varName
                       _ <- reservedOp ":"
                       t <- term
                       return $ [ DeclArg Impl x t | x <- xs ]

alternativeArg = explAlternativeArg <|> implAlternativeArg

alternativeArgs = do argss <- many alternativeArg
                     return (concat argss)

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

explTypeArg = parens $ do
                x <- varName
                _ <- reservedOp ":"
                t <- term
                return $ DeclArg Expl x t

implTypeArg = braces $ do
                x <- varName
                _ <- reservedOp ":"
                t <- term
                return $ DeclArg Impl x t

typeArg = explTypeArg <|> implTypeArg

typeDecl = emptyTypeDecl <|> nonEmptyTypeDecl

statement = TmDecl <$> termDecl
        <|> TyDecl <$> typeDecl

modulOpen = do n <- try $ do
                 _ <- reserved "module"
                 n <- decName
                 _ <- reserved "opening"
                 return n
               _ <- optional (reserved "|")
               settings <- sepBy openSettings (reserved "|")
               _ <- reserved "where"
               stmts <- many statement
               _ <- reserved "end"
               return $ Module n settings stmts

modulNoOpen = do n <- try $ do
                   _ <- reserved "module"
                   n <- decName
                   _ <- reserved "where"
                   return n
                 stmts <- many statement
                 _ <- reserved "end"
                 return $ Module n [] stmts

modul = modulOpen <|> modulNoOpen

program = Program <$> many modul



parseProgram :: String -> Either String Program
parseProgram str
  = case parse (spaces *> program <* eof) "(unknown)" str of
      Left e -> Left (show e)
      Right p -> Right p