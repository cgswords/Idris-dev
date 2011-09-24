{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances #-}

module Evaluate(normalise,
                Fun(..), Def(..), Context,
                emptyContext, addToCtxt, addConstant,
                lookupTy, lookupP, lookupVal, lookupTyEnv) where

import Debug.Trace
import Core

-- VALUES (as HOAS) ---------------------------------------------------------

data Value = VP NameType Name Value
           | VV Int
           | VBind Name (Binder Value) (Value -> Value)
           | VApp Value Value
           | VSet Int
           | VTmp Int

instance Show Value where
    show = show . quote 0

-- THE EVALUATOR ------------------------------------------------------------

normalise :: Context -> Env -> TT Name -> TT Name
normalise ctxt env t = quote 0 (eval ctxt (weakenEnv env) t)

eval :: Context -> Env -> TT Name -> Value
eval ctxt genv tm = ev [] tm where
    ev env (P Ref n ty)
        | Just v <- lookupVal n ctxt = v -- FIXME! Needs evalling
    ev env (P nt n ty)   = VP nt n (ev env ty)
    ev env (V i) | i < length env = env !! i
                 | i < length env + length genv 
                       = case genv !! (i - length env) of
                             (_, Let t v) -> ev env v
                             _            -> VV i
                 | otherwise      = error $ "Internal error: V" ++ show i
    ev env (Bind n (Let t v) sc)
           = ev (ev env v : env) sc
    ev env (Bind n b sc) = VBind n (vbind env b) (\x -> ev (x:env) sc)
       where vbind env t = fmap (ev env) t    
    ev env (App f a) = evApply env [a] f
    ev env (Set i)   = VSet i
    
    evApply env args (App f a) = evApply env (a:args) f
    evApply env args f = apply env (ev env f) args

    apply env (VBind n (Lam t) sc) (a:as) = apply env (sc (ev env a)) as
    apply env f                    (a:as) = unload env f (a:as)
    apply env f                    []     = f

    unload env f [] = f
    unload env f (a:as) = unload env (VApp f (ev env a)) as

quote :: Int -> Value -> TT Name
quote i (VP nt n v)    = P nt n (quote i v)
quote i (VV x)         = V x
quote i (VBind n b sc) = Bind n (quoteB b) (quote (i+1) (sc (VTmp (i+1))))
   where quoteB t = fmap (quote i) t
quote i (VApp f a)     = App (quote i f) (quote i a)
quote i (VSet u)       = Set u
quote i (VTmp x)       = V (i - x)


-- CONTEXTS -----------------------------------------------------------------

data Fun = Fun Type Value Term Value
  deriving Show

data Def = Function Fun
         | Constant NameType Type Value
  deriving Show

type Context = [(Name, Def)]

emptyContext = []

addToCtxt :: Name -> Term -> Type -> Context -> Context
addToCtxt n tm ty ctxt = (n, Function (Fun ty (eval ctxt [] ty)
                                           tm (eval ctxt [] tm))) : ctxt

addConstant :: Name -> Type -> Context -> Context
addConstant n ty ctxt = (n, Constant Ref ty (eval ctxt [] ty)) : ctxt

lookupTy :: Name -> Context -> Maybe Type
lookupTy n ctxt = do def <-  lookup n ctxt
                     case def of
                       (Function (Fun ty _ _ _)) -> return ty
                       (Constant _ ty _) -> return ty

lookupP :: Name -> Context -> Maybe Term
lookupP n ctxt 
   = do def <-  lookup n ctxt
        case def of
          (Function (Fun ty _ tm _)) -> return (P Ref n ty)
          (Constant nt ty hty) -> return (P nt n ty)

lookupVal :: Name -> Context -> Maybe Value
lookupVal n ctxt 
   = do def <- lookup n ctxt
        case def of
          (Function (Fun _ _ _ htm)) -> return htm
          (Constant nt ty hty) -> return (VP nt n hty)

lookupTyEnv :: Name -> Env -> Maybe (Int, Type)
lookupTyEnv n env = li n 0 env where
  li n i []           = Nothing
  li n i ((x, b): xs) 
             | n == x = Just (i, binderTy b)
             | otherwise = li n (i+1) xs
