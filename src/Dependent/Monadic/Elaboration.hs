module Dependent.Monadic.Elaboration where

import Control.Applicative ((<$>))
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Data.List (intercalate)
import Data.Maybe (isJust)

import Abs
import Scope
import TypeChecker (extendDefinitions)
import Dependent.Core.Abstraction
import Dependent.Core.ConSig
import Dependent.Core.Program
import Dependent.Core.Term

import Dependent.Monadic.TypeChecking



data ElabState
  = ElabState
    { elabSig :: Signature Term
    , elabDefs :: Definitions
    , elabCtx :: Context
    , elabNextName :: Int
    }

type Elaborator a = StateT ElabState (Either String) a

runElaborator :: Elaborator () -> Either String ElabState
runElaborator elab = do (_,p) <- runStateT elab (ElabState [] [] [] 0)
                        return p

signature :: Elaborator (Signature Term)
signature = elabSig <$> get

context :: Elaborator Context
context = elabCtx <$> get

definitions :: Elaborator Definitions
definitions = elabDefs <$> get

putSignature :: Signature Term -> Elaborator ()
putSignature sig = do s <- get
                      put (s { elabSig = sig })

putContext :: Context -> Elaborator ()
putContext ctx = do s <- get
                    put (s { elabCtx = ctx})

putDefinitions :: Definitions -> Elaborator ()
putDefinitions defs = do s <- get
                         put (s {elabDefs = defs })

when' :: TypeChecker a -> Elaborator () -> Elaborator ()
when' tc e = do ElabState sig defs ctx i <- get
                case runTypeChecker tc sig defs ctx i of
                  Left _  -> return ()
                  Right _ -> e

liftTC :: TypeChecker a -> Elaborator a
liftTC tc = do ElabState sig defs ctx i <- get
               case runTypeChecker tc sig defs ctx i of
                 Left e  -> throwError e
                 Right (a,s) -> do s' <- get
                                   put s' { elabNextName = tcNextName s }
                                   return a


addDeclaration :: String -> Term -> Term -> Elaborator ()
addDeclaration n def ty = do defs <- definitions
                             putDefinitions ((n,def,ty) : defs)

addConstructor :: String -> ConSig Term -> Elaborator ()
addConstructor c consig
  = do sig <- signature
       putSignature ((c,consig):sig)




elabTermDecl :: TermDeclaration -> Elaborator ()
elabTermDecl (TermDeclaration n ty def)
  = do when' (typeInDefinitions n)
           $ throwError ("Term already defined: " ++ n)
       liftTC (check ty Type)
       liftTC (extendDefinitions [(n,def,ty)] (check def ty))
       addDeclaration n def ty
elabTermDecl (WhereDeclaration n ty preclauses)
  = case preclauses of
      [] -> throwError "Cannot create an empty let-where definition."
      [(ps,xs,b)] | all isVarPat ps
         -> elabTermDecl (TermDeclaration n ty (helperFold lamHelper xs b))
      (ps0,_,_):_
        -> do let clauses = [ clauseHelper ps xs b | (ps,xs,b) <- preclauses ]
                  psLength = length ps0
                  mot = motiveAux psLength ty
              unless (psLength <= functionArgsLength ty)
                $ throwError $ "Cannot build a case expression motive for fewer than " ++ show psLength
                      ++ " args from the type " ++ show ty
              elabTermDecl (TermDeclaration n ty (lambdaAux (\as -> Case as mot clauses) psLength))
  where
    isVarPat :: Pattern -> Bool
    isVarPat (VarPat _) = True
    isVarPat _ = False
    
    lambdaAux :: ([Term] -> Term) -> Int -> Term
    lambdaAux f 0 = f []
    lambdaAux f n = Lam (Scope ["_" ++ show n] $ \[x] -> lambdaAux (f . (x:)) (n-1))
    
    functionArgsLength :: Term -> Int
    functionArgsLength (Fun _ sc) = 1 + functionArgsLength (descope (Var . Name) sc)
    functionArgsLength _          = 0
    
    motiveAux :: Int -> Term -> CaseMotive
    motiveAux 0 t = CaseMotiveNil t
    motiveAux n (Fun a (Scope ns b)) = CaseMotiveCons a (Scope ns (motiveAux (n-1) . b))



elabAlt :: String -> String -> ConSig Term -> Elaborator ()
elabAlt tycon c consig
  = do validConSig consig
       when' (typeInSignature c)
           $ throwError ("Constructor already declared: " ++ c)
       liftTC (checkConSig consig)
       addConstructor c consig
  where
    validConSig :: ConSig Term -> Elaborator ()
    validConSig (ConSigNil (Con tc _))
      = unless (tc == tycon)
          $ throwError $ "The constructor " ++ c ++ " should constructor a value of the type " ++ tycon
                      ++ " but instead produces a " ++ tc
    validConSig (ConSigNil a)
      = throwError $ "The constructor " ++ c ++ " should constructor a value of the type " ++ tycon
                  ++ " but instead produces " ++ show a
    validConSig (ConSigCons _ sc)
      = validConSig (descope (Var . Name) sc)

elabTypeDecl :: TypeDeclaration -> Elaborator ()
elabTypeDecl (TypeDeclaration tycon tyconargs alts)
  = do let tyconSig = conSigHelper tyconargs Type
       when' (typeInSignature tycon)
           $ throwError ("Type constructor already declared: " ++ tycon)
       liftTC (checkConSig tyconSig)
       addConstructor tycon tyconSig
       mapM_ (uncurry (elabAlt tycon)) alts



elabProgram :: Program -> Elaborator ()
elabProgram (Program stmts) = go stmts
  where
    go :: [Statement] -> Elaborator ()
    go [] = return ()
    go (TyDecl td:stmts) = do elabTypeDecl td
                              go stmts
    go (TmDecl td:stmts) = do elabTermDecl td
                              go stmts