{-# LANGUAGE FlexibleContexts #-}
module Lambda.Inference where

import Data.Maybe
import Data.Foldable
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Except
import Control.Monad.Identity
import Control.Monad (when, replicateM, foldM)
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Lambda.Calculus as C
import Debug.Trace

data TypeError = CannotUnify C.Type C.Type
               | InfiniteType String C.Type
               | EffectTailCheck String
               | UnboundVariable String
               | Inside C.Expr TypeError
               deriving Show

type InfererT m a = ExceptT TypeError (ReaderT () (StateT Int m)) a
type ExceptionControl = ExceptT TypeError (ReaderT () (StateT Int Identity)) (M.Map String C.Type, C.Type, C.Type)

runInferer' i = do
    (res, _) <- runStateT (runReaderT (runExceptT i) ()) 0
    return res

newTypeVar = do
  s <- get
  modify (+1)
  return $ C.Generic (letters !! s)
  where
    letters = [1..] >>= flip replicateM ['a'..'z']

generalize :: C.Substitutable p => p -> C.Type -> C.Scheme
generalize g t =
    C.Forall vars t
    where
        vars = S.toList ((C.ftv t) `S.difference` (C.ftv g))

instantiate (C.Forall vars t) = do
    nvars <- mapM (const $ newTypeVar) vars
    let m = M.fromList (zip vars nvars)
    return $ C.subst m t

unify (C.Arrow a e b) (C.Arrow x f y) = do
    theta1 <- unify a x
    theta2 <- unify (C.subst theta1 e) (C.subst theta1 f)
    theta3 <- unify (C.subst (theta2 C.@@ theta1) b) (C.subst (theta2 C.@@ theta1) y)
    return $ theta3 C.@@ theta2 C.@@ theta1
unify (C.Generic a) t = do
    varBind a t
unify t (C.Generic a) = do
    varBind a t
unify C.Unit C.Unit = do
    return M.empty
unify C.Int C.Int = do
    return M.empty
unify C.Bool C.Bool = do
    return M.empty
unify C.Pure C.Pure = do
    return M.empty
unify C.Console C.Console = do
    return M.empty
unify C.Foo C.Foo = do
    return M.empty
unify C.Bar C.Bar = do
    return M.empty
unify (C.Ref a) (C.Ref b) = do
    unify a b
unify (C.State) (C.State) = do
    return M.empty
unify (C.Constant a []) (C.Constant b []) | a == b = do
    return M.empty
unify (C.Constant a (x:xs)) (C.Constant b (y:ys)) | a == b = do
    theta1 <- unify (C.Constant a xs) (C.Constant a ys)
    theta2 <- unify (C.subst theta1 x) (C.subst theta1 y)
    return $ theta2 C.@@ theta1
unify C.String C.String = do
    return M.empty
unify foo@(C.Row l epsilon1) epsilon2 = do
    --traceM $ "\nUnifying (l = " ++ show l ++ ", epsilon1 = " ++ show epsilon1 ++ ") " ++
    --    " with epsilon2 = " ++ show epsilon2
    (epsilon3, theta1) <- unifyEffect epsilon2 l
    -- Sanity check, this is stated in Koka's paper to be true
    --traceM $ "unifyEffect returned = " ++ show (epsilon3, theta1)
    if C.rowsEquiv (C.subst theta1 epsilon2) (C.Row (C.subst theta1 l) (C.subst theta1 epsilon3))
        then return ()
        else do
            --traceM $ "We know that " ++ show (C.subst theta1 epsilon2)
            --traceM $ "should equal " ++ show (C.Row (C.subst theta1 l) (C.subst theta1 epsilon3))
            -- TODO: better this message. 
            error "Fatal error DEU RUIM"

    when (M.member (tl epsilon1) theta1) $ do
    -- traceM $ "tl(epsilon1) = " ++ show (tl epsilon1)
        throwError $ EffectTailCheck (tl epsilon1)
    -- traceM $ "Now unifying " ++ show (C.subst theta1 epsilon1) ++ " and " ++
    --    show (C.subst theta1 epsilon3)
    theta2 <- unify (C.subst theta1 epsilon1) (C.subst theta1 epsilon3)
    -- traceM $ "theta2 = " ++ show theta2
    -- traceM $ "RESULT = " ++ show (theta2 C.@@ theta1)
    return (theta2 C.@@ theta1)
    where
        tl (C.Row _ tail) =
            tl tail
        tl C.Pure =
            "---"
        tl (C.Generic a) =
            a

unify a b = do
    throwError $ CannotUnify a b

-- The unify effects comes directly from Koka paper:
-- https://arxiv.org/pdf/1406.2061.pdf
-- or in this repository with name 1406.2061.pdf
-- pag 110
unifyEffect (C.Row l' epsilon) l =
    -- (EFF-HEAD)
    if l == l' then do
        theta <- unify l l'
        return (epsilon, theta)
    -- (EFF-SWAP)
    else do
    -- We've been found a error in the algorithm: 
    -- Koka's paper says we should return l on tail,
    -- but we actually return l' here, otherwise the algorithm "DÁ RUIM". 
        (epsilon', theta) <- unifyEffect epsilon l
        return (C.Row l' epsilon', theta)
unifyEffect (C.Generic mu) l = do
    mu' <- newTypeVar
    return (mu', M.singleton mu (C.Row l mu'))
unifyEffect a b = do
    throwError $ CannotUnify a b

varBind a t | t == C.Generic a =
                return M.empty
            | a `S.member` C.ftv t =
                throwError $ InfiniteType a t
            | otherwise =
                return $ M.singleton a t

--
infer :: C.Environment -> C.Expr -> ExceptionControl
infer (C.Environment env) (C.Free s) =
    case M.lookup s env of
        Just sigma -> do
            t <- instantiate sigma
            mi <- newTypeVar
            return (M.empty, t, mi)
        Nothing ->
            throwError $ UnboundVariable s
infer _ (C.Number _) = do
    mi <- newTypeVar
    return (M.empty, C.Int, mi)
infer _ (C.Text _) = do
    mi <- newTypeVar
    return (M.empty, C.String, mi)
infer _ (C.UnitValue) = do
    mi <- newTypeVar
    return (M.empty, C.Unit, mi)
infer _ (C.TrueValue) = do
    mi <- newTypeVar
    return (M.empty, C.Bool, mi)
infer _ (C.FalseValue) = do
    mi <- newTypeVar
    return (M.empty, C.Bool, mi)
infer env (C.Lambda x e) = do
    alpha <- newTypeVar
    (theta, tau2, epsilon2) <- infer (C.extend' env x alpha) e
    mi <- newTypeVar
    return (theta, C.Arrow (C.subst theta alpha) epsilon2 tau2, mi)
infer env expr@(C.Application e1 e2) = do
    (theta1, tau1, epsilon1) <- infer env e1
    (theta2, tau2, epsilon2) <- infer (C.subst theta1 env) e2
    alpha <- newTypeVar
    theta3 <- unify (C.subst theta2 tau1) (C.Arrow tau2 epsilon2 alpha)
    theta4 <- unify (C.subst (theta3 C.@@ theta2) epsilon1) (C.subst theta3 epsilon2)
    return (theta4 C.@@ theta3 C.@@ theta2 C.@@ theta1,
                C.subst (theta4 C.@@ theta3) alpha,
                    C.subst (theta4 C.@@ theta3) epsilon2)
infer env (C.Let x e1 e2) = do
    (s1, t1, k1) <- infer env e1
    let C.Environment env' = C.remove env x
    let t' = generalize (C.subst s1 env) t1
    let env'' = C.Environment (M.insert x t' env')
    s2 <- unify k1 C.Pure
    (s3, t2, k2) <- infer (C.subst (s2 C.@@ s1) env'') e2
    return (s3 C.@@ s2 C.@@ s1, t2, k2)

infer env (C.Where bindings e) = do
    -- Assume we have:
    -- e where { e_1; e_2; ...; e_n }
    -- We first have to gather a fresh var alpha_i for each block e_i
    alpha <- mapM (const newTypeVar) bindings
    --
    -- We'll extend our context with the proper vars, i.e.,
    --   G, e_1: alpha_1, e_2: alpha_2, ..., e_n: alpha_n |-
    let env' = foldl (\acc (var, (block, _)) ->
                   C.extend' acc block var) env (zip alpha bindings)
    -- We now fold left the blocks, accumulating the substitution
    (env'', theta) <- foldlM inferBlock (env', M.empty) (zip alpha bindings)
    --traceM $ "\nRetuned theta = " ++ show theta
    --traceM $ "Returned env'' = " ++ show env''
    if (C.subst theta env') /= env''
        then
            error "DEU MUITO RUIM!!!"
        else
            return ()
    (theta2, tau2, epsilon2) <- infer env'' e
    --traceM $ "  theta2 = " ++ show theta2
    --traceM $ "  tau2 = " ++ show tau2
    --traceM $ "  epsilon2 = " ++ show epsilon2
    --traceM $ "  composition = " ++ show (theta2 C.@@ theta)
    return (theta2 C.@@ theta, tau2, epsilon2)

    where
        inferBlock (env', theta_i) (alpha, (var, block)) = do
            --traceM $ "  env' = " ++ show env'
            (theta_i', tau, epsilon) <- infer env' block
            --traceM $ "  returned theta_i' = " ++ show theta_i'
            --traceM $ "  returned tau = " ++ show tau
            --traceM $ "  returned epsilon = " ++ show epsilon
            let alpha' = C.subst (theta_i' C.@@ theta_i) alpha
            theta_i'' <- unify alpha' tau
            --traceM $ "  after unification = " ++ show theta_i''
            let env'' = C.subst (theta_i'' C.@@ theta_i') env'
            --traceM $ "  new env'' = " ++ show env''
            return (env'', theta_i'' C.@@ theta_i' C.@@ theta_i)

infer env (C.Operation C.Sum a b) = do
    infer env (C.Application (C.Application (C.Free "(+)") a) b)
infer env (C.Operation C.Sub a b) = do
    infer env (C.Application (C.Application (C.Free "(-)") a) b)
infer env (C.Operation C.Mul a b) = do
    infer env (C.Application (C.Application (C.Free "(*)") a) b)
infer env (C.Operation C.Div a b) = do
    infer env (C.Application (C.Application (C.Free "(/)") a) b)
infer env (C.Operation C.Lt a b) = do
    infer env (C.Application (C.Application (C.Free "(<)") a) b)
infer env (C.Operation C.Gt a b) = do
    infer env (C.Application (C.Application (C.Free "(>)") a) b)
infer env (C.Operation C.Eq a b) = do
    infer env (C.Application (C.Application (C.Free "(=)") a) b)
infer env (C.If a b c) = do
    infer env (C.Application (C.Application (C.Application (C.Free "(?:)") a) b) c)

infer env (C.Handler eff branches e) = do
    let pure = lookup Nothing branches
    let cases = filter (isJust . fst) branches
    --
    epsilon <- newTypeVar
    -- First, we have to check the return type of our pure expression, which
    -- always take just one argument
    inferred <- case pure of
                    Just expr ->
                       infer env expr
                    Nothing ->
                       infer env (C.Lambda "" (C.Free ""))
    let (theta_p, tau_p, C.Generic _) = inferred
    -- traceM $ show (theta_p, tau_p)
    -- We have to check which is the return type of the pure expression
    tau_x1 <- newTypeVar
    tau_x2 <- newTypeVar
    theta_x <- unify (C.Arrow tau_x1 epsilon tau_x2) tau_p
    -- traceM $ show theta_x
    -- Now, we must accumulate the subst of each case, each with its own resume
    theta <- foldM (inferCase tau_x2 epsilon) (theta_x C.@@ theta_p) cases
    let epsilon_r = C.subst theta epsilon
    (theta_e, tau_e, epsilon_e) <- infer env e
    traceM $ "Type of expression itself:"
    traceM $ show (theta_e, tau_e, epsilon_e)
    theta_a <- unify tau_e (C.subst (theta_e C.@@ theta) tau_x1)
    traceM $ show theta_a
    theta_b <- unify epsilon_e (C.subst theta_e (C.Row (C.Constant eff []) epsilon_r))
  
    let theta_acc = theta_b C.@@ theta_a C.@@ theta_e C.@@ theta
    return (theta_acc, C.subst (theta_acc) tau_x2, C.subst (theta_b C.@@ theta_a) epsilon_r)
    
    where
        inferCase tau_x2 epsilon theta (Just name, expr) = do
            -- Here we need the return type of the effectful function; we use
            -- an auxiliry function to find it diretly from the context
            -- Note that any substitution won't change our environment so far
            let actual_type = (C.getEnvironment env) M.! name
            let (params, tau_i) = getReturn actual_type
            -- traceM $ "The return type of " ++ name ++ " is " ++ show tau_i
            -- We have received the expressions as lambda exprs, so we don't
            -- care about their parameters... we just have to extend the context
            -- with the resume operation
            let resume_type = C.Forall params (C.Arrow tau_i (C.subst theta epsilon) (C.subst theta tau_x2))
            -- traceM $ "The type of `resume` under " ++ name ++ " is: " ++ show resume_type
            let env' = C.extend env "resume" resume_type
            -- We can now infer the body itself...
            (theta_e, tau_e, epsilon_e) <- infer env' expr
            -- traceM $ "We infered it to have type " ++ show (tau_e, epsilon_e)
            -- Make sure that the given parameters and return are correct!
            let tau_x2' = C.subst (theta_e C.@@ theta) tau_x2
            let epsilon' = C.subst (theta_e C.@@ theta) epsilon
            expectedType <- getExpectedType tau_x2' epsilon' actual_type
            -- traceM $ "We expect this branch to have type " ++ show expectedType
            --
            theta' <- unify tau_e expectedType
            theta'' <- unify (C.subst theta' epsilon_e) (C.subst theta' epsilon')
            --
            return $ theta'' C.@@ theta' C.@@ theta_e C.@@ theta

        getReturn (C.Forall _ (C.Arrow a (C.Row (C.Constant u _) _) b)) =
            if u /= eff then
                -- Should never happen
                error $ show ("internal compiler error", u, eff)
            else
                -- We don't have any type variables in effects (yet), but we
                -- whould return those here
                ([], b)
        getReturn (C.Forall v (C.Arrow a (C.Generic _) b)) =
            getReturn (C.Forall v b)
        getReturn x =
            error $ show ("unexpected type in env!", x)

        -- TODO: Note, this function only works because we are ignoring type
        -- parameters for effectful computations!!!
        getExpectedType tau_x2 epsilon (C.Forall _ (C.Arrow a (C.Row (C.Constant u []) _) _)) =
            if u /= eff then
                -- Should never happen
                error $ show ("internal compiler error", u, eff)
            else do
                return $ C.Arrow a epsilon tau_x2
        getExpectedType tau_x2 epsilon (C.Forall v (C.Arrow a (C.Generic _) b)) = do
            traceM "AAAAAAA"
            var <- newTypeVar
            tail <- getExpectedType tau_x2 epsilon (C.Forall v b)
            return $ C.Arrow a var tail
        getExpectedType _ _ x =
            error $ show ("unexpected type in env!", x)

initialEnvironment :: C.Environment
initialEnvironment =
    C.Environment (M.fromList [
        ("print", C.Forall ["a", "u"] $ C.Arrow (C.Generic "a") (C.Row C.Console $ C.Generic "u") C.Unit),
        --("foo", C.Forall ["u"] $ C.Arrow C.Int (C.Row C.Foo $ C.Generic "u") C.Int),
        --("bar", C.Forall ["u"] $ C.Arrow C.Int (C.Row C.Bar $ C.Generic "u") C.Int),
        ("apply", C.Forall ["a", "b", "u"] $ C.Arrow (C.Arrow (C.Generic "a") (C.Generic "u") (C.Generic "b")) (C.Generic "u") $
            C.Arrow (C.Generic "a") (C.Generic "u") (C.Generic "b")),
        ("_newSTVar",
            -- newSTVar: a -> <st<h>, u> ref<h, a>
            C.Forall ["a", "u"] $
                C.Arrow (C.Generic "a") (C.Row C.State (C.Generic "u")) $
                    C.Ref (C.Generic "a")),
        ("_writeSTVar",
            -- writeSTVar: ref<h, a> -> u a -> <st<h>, v> unit
            C.Forall ["a", "u", "v"] $
                C.Arrow (C.Ref (C.Generic "a")) (C.Generic "u") $
                    C.Arrow (C.Generic "a") (C.Row C.State (C.Generic "v")) C.Unit),
        ("_readSTVar",
            -- readSTVar: ref<h, a> -> <st<h>, u> a
            C.Forall ["a", "u"] $
                C.Arrow (C.Ref (C.Generic "a"))
                    (C.Row C.State (C.Generic "u")) (C.Generic "a")),
        ("nothing", C.Forall ["a", "u"] $ C.Arrow C.Unit (C.Generic "u")
                        (C.Constant "Maybe" [C.Generic "a"])),
        ("just", C.Forall ["a", "u"] $ C.Arrow (C.Generic "a") (C.Generic "u")
                        (C.Constant "Maybe" [C.Generic "a"])),
        -- Example for how we can remove a effect from a closure
        --("removeFoo",
        --    C.Forall ["a", "b", "u"] $
        --        C.Arrow
        --            (C.Arrow (C.Generic "a") (C.Row C.Foo (C.Generic "u")) (C.Generic "a"))
        --            (C.Pure)
        --            (C.Arrow (C.Generic "a") (C.Generic "u") (C.Generic "a")))
        --("fix", C.Forall ["'a"] $
        --    C.Arrow (C.Arrow (C.Generic "'a") (C.Generic "'a")) (C.Generic "'a")),
        ("error", C.Forall ["a", "u"] $ C.Arrow C.String (C.Generic "u")
            (C.Generic "a")),
        ("(+)", C.Forall ["u"] $ C.Arrow C.Int (C.Generic "u")
            (C.Arrow C.Int (C.Generic "u") C.Int)),
        ("(-)", C.Forall ["a", "b"] $ C.Arrow C.Int (C.Generic "a")
            (C.Arrow C.Int (C.Generic "b") C.Int)),
        ("(*)", C.Forall ["a", "b"] $ C.Arrow C.Int (C.Generic "a")
            (C.Arrow C.Int (C.Generic "b") C.Int)),
        ("(/)", C.Forall ["a", "b"] $ C.Arrow C.Int (C.Generic "a")
            (C.Arrow C.Int (C.Generic "b") C.Int)),
        ("(<)", C.Forall ["u"] $ C.Arrow C.Int (C.Generic "u")
            (C.Arrow C.Int (C.Generic "u") C.Bool)),
        ("(>)", C.Forall ["u"] $ C.Arrow C.Int (C.Generic "u")
            (C.Arrow C.Int (C.Generic "u") C.Bool)),
        ("(=)", C.Forall ["u"] $ C.Arrow C.Int (C.Generic "u")
            (C.Arrow C.Int (C.Generic "u") C.Bool)),
        ("(?:)", C.Forall ["a", "u"] $ C.Arrow C.Bool (C.Generic "u")
            (C.Arrow (C.Generic "a") (C.Generic "u")
                (C.Arrow (C.Generic "a") (C.Generic "u")
                    (C.Generic "a"))))
    ])

runInferer :: C.Expr -> C.Environment -> C.Scheme
runInferer e g =
    case runIdentity runInfererM of
      Right scheme -> scheme
      Left message -> error $ show message
    where
        runInfererM =
            runInferer' $ do
                (s, t, k) <- infer g e
                put 0
                result <- instantiate $ generalize g t
                return $ generalize g result
