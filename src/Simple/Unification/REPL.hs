module Simple.Unification.REPL where

import Control.Monad.Reader
import System.IO

import Env
import Eval
import Simple.Unification.Elaboration
import Simple.Unification.TypeChecking
import Simple.Core.Evaluation
import Simple.Core.Parser
import Simple.Core.Term

flushStr :: String -> IO ()
flushStr str = putStr str >> hFlush stdout

readPrompt :: String -> IO String
readPrompt prompt = flushStr prompt >> getLine

until_ :: Monad m => (a -> Bool) -> m a -> (a -> m ()) -> m ()
until_ p prompt action = do 
   result <- prompt
   if p result 
      then return ()
      else action result >> until_ p prompt action

repl :: String -> IO ()
repl src = case loadProgram src of
             Left e -> flushStr e
             Right (sig,defs,ctx,env)
               -> do hSetBuffering stdin LineBuffering
                     until_ (== ":quit")
                            (readPrompt "$> ")
                            (evalAndPrint sig defs ctx env)
  where
    loadProgram :: String -> Either String (Signature,Definitions,Context,Environment String Term)
    loadProgram src
      = do prog <- parseProgram src
           (sig,defs,ctx) <- runElaborator (elabProgram prog)
           let env = [ (x,m) | (x,m,_) <- defs ]
           return (sig,defs,ctx,env)
    
    loadTerm :: Signature -> Definitions -> Context -> Environment String Term -> String -> Either String Term
    loadTerm sig defs ctx env src
      = do tm <- parseTerm src
           case runTypeChecker (infer tm) sig defs (contextToPatternContext ctx) of
             Nothing -> Left "Unable to infer type."
             Just _ -> runReaderT (eval tm) env
    
    evalAndPrint :: Signature -> Definitions -> Context -> Environment String Term -> String -> IO ()
    evalAndPrint _ _ _ _ "" = return ()
    evalAndPrint sig defs ctx env src
      = case loadTerm sig defs ctx env src of
          Left e -> flushStr (e ++ "\n")
          Right v -> flushStr (show v ++ "\n")

replFile :: String -> IO ()
replFile loc = readFile loc >>= repl