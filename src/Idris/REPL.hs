{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, DeriveFunctor,
             PatternGuards #-}

module Idris.REPL where

import Idris.AbsSyntax
import Idris.REPLParser
import Idris.ElabDecls
import Idris.Error
import Idris.Delaborate
import Idris.Compiler
import Idris.Prover
import Idris.Parser
import Paths_idris

import Core.Evaluate
import Core.ProofShell
import Core.TT

import System.Console.Readline
import System.FilePath
import System.Environment
import System.Process
import Control.Monad
import Control.Monad.State
import Data.List
import Data.Char
import Data.Version

repl :: IState -> [FilePath] -> Idris ()
repl orig mods
     = do let prompt = mkPrompt mods
          x <- lift $ readline (prompt ++ "> ")
          case x of
              Nothing -> repl orig mods
              Just input -> do lift $ addHistory input
                               ms <- processInput input orig mods
                               case ms of
                                    Just mods -> repl orig mods
                                    Nothing -> return ()

mkPrompt [] = "Idris"
mkPrompt [x] = "*" ++ dropExtension x
mkPrompt (x:xs) = "*" ++ dropExtension x ++ " " ++ mkPrompt xs

processInput :: String -> IState -> [FilePath] -> Idris (Maybe [FilePath])
processInput cmd orig inputs
    = do i <- get
         let fn = case inputs of
                        (f:_) -> f
                        _ -> ""
         case parseCmd i cmd of
                Left err ->   do lift $ print err
                                 return (Just inputs)
                Right Reload -> do put orig
                                   clearErr
                                   mods <- mapM loadModule inputs  
                                   return (Just inputs)
                Right Quit -> do iputStrLn "Bye bye"
                                 return Nothing
                Right cmd  -> do idrisCatch (process fn cmd)
                                            (\e -> iputStrLn (report e))
                                 return (Just inputs)
 
process :: FilePath -> Command -> Idris ()
process _ Help = iputStrLn displayHelp
process "" Edit = iputStrLn "Nothing to edit"
process f Edit
    = do i <- get
         env <- lift $ getEnvironment
         let editor = getEditor env
         let line = case errLine i of
                        Just l -> " +" ++ show l ++ " "
                        Nothing -> " "
         let cmd = editor ++ line ++ f
         lift $ system cmd
         return ()
   where getEditor env | Just ed <- lookup "EDITOR" env = ed
                       | Just ed <- lookup "VISUAL" env = ed
                       | otherwise = "vi"
process _ (Eval t) = do (tm, ty) <- elabVal toplevel False t
                        ctxt <- getContext
                        ist <- get 
                        let tm' = normaliseC ctxt [] tm
                        let ty' = normaliseC ctxt [] ty
                        logLvl 3 $ "Raw: " ++ show (tm', ty')
                        iputStrLn (show (delab ist tm') ++ " : " ++ 
                                   show (delab ist ty'))
process _ (Spec t) = do (tm, ty) <- elabVal toplevel False t
                        ctxt <- getContext
                        ist <- get
                        let tm' = specialise ctxt (idris_statics ist) tm
                        iputStrLn (show (delab ist tm'))
process _ (Prove n) = prover n
process _ (HNF t)  = do (tm, ty) <- elabVal toplevel False t
                        ctxt <- getContext
                        ist <- get
                        let tm' = hnf ctxt [] tm
                        iputStrLn (show (delab ist tm'))
process _ TTShell  = do ist <- get
                        let shst = initState (tt_ctxt ist)
                        shst' <- lift $ runShell shst
                        return ()
process _ (Compile f) = do compile f 
process _ (LogLvl i) = setLogLevel i 
process _ Metavars = do ist <- get
                        let mvs = idris_metavars ist \\ primDefs
                        case mvs of
                          [] -> iputStrLn "No global metavariables to solve"
                          _ -> iputStrLn $ "Global metavariables:\n\t" ++ show mvs
process _ NOP      = return ()

displayHelp = let vstr = showVersion version in
              "\nIdris version " ++ vstr ++ "\n" ++
              "--------------" ++ map (\x -> '-') vstr ++ "\n\n" ++
              concatMap cmdInfo help
  where cmdInfo (cmds, args, text) = "   " ++ col 14 14 (showSep " " cmds) args text 
        col c1 c2 l m r = 
            l ++ take (c1 - length l) (repeat ' ') ++ 
            m ++ take (c2 - length m) (repeat ' ') ++ r ++ "\n"

help =
  [ (["Command"], "Arguments", "Purpose"),
    ([""], "", ""),
    (["<expression>"], "", "Evaluate an expression"),
    ([":r",":reload"], "", "Reload current file"),
    ([":e",":edit"], "", "Edit current file using $EDITOR or $VISUAL"),
    ([":m",":metavars"], "", "Show remaining proof obligations (metavariables)"),
    ([":p",":prove"], "<name>", "Prove a metavariable"),
    ([":c",":compile"], "<filename>", "Compile to an executable <filename>"),
    ([":?",":h",":help"], "", "Display this help text"),
    ([":q",":quit"], "", "Exit the Idris system")
  ]
