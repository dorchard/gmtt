{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PatternSynonyms #-}

{-# options_ghc -fno-warn-incomplete-uni-patterns -Wno-deprecations #-}
module Language.Granule.Synthesis.Synth where

--import Data.List
--import Control.Monad (forM_)
import Debug.Trace
import System.IO.Unsafe

import Language.Granule.Syntax.Def
import Language.Granule.Syntax.Expr
import Language.Granule.Syntax.Type
--import Language.Granule.Syntax.FirstParameter
import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Pattern
import Language.Granule.Syntax.Pretty

import Language.Granule.Context

import Language.Granule.Checker.Checker
import Language.Granule.Checker.Constraints
import Language.Granule.Checker.Monad
import Language.Granule.Checker.Predicates
import Language.Granule.Checker.Substitution
import Language.Granule.Checker.SubstitutionContexts
import Language.Granule.Checker.Types
import Language.Granule.Checker.Variables
import Language.Granule.Syntax.Span

import Data.List.NonEmpty (NonEmpty(..))
import Control.Monad.Except
import qualified Control.Monad.State.Strict as State (get, liftIO, modify)
import Control.Monad.Trans.List
import Control.Monad.Trans.State.Strict

import Language.Granule.Utils

data Configuration = Config
   { churchSyntax            :: Bool,
     howManyNatPossibilities :: Int
    }

canUse :: Coeffect -> Bool
canUse (CNat n) = (n > 0)
canUse (CInterval (CNat _) (CNat n2)) = (n2 > 0)
canUse (CInfinity _) = True
canUse _ = False

zeroUse :: Coeffect -> Bool
zeroUse (CNat n) = (n == 0)
zeroUse (CInterval (CNat n1) (CNat _)) = (n1 == 0)
zeroUse (CInfinity _) = True
zeroUse _ = False

zero :: Coeffect -> Type
zero (CNat _) = TyCon $ mkId "Nat"
zero (CInterval c1 c2) = TyApp (TyCon $ mkId "Interval") (zero c1)

testVal :: (?globals :: Globals) => Bool
testVal  = do
  --addConstraint (ApproximatedBy nullSpanNoFile (CNat 0) (CZero $ zero (CNat 0) ) (zero (CNat 0)))
  case unsafePerformIO $ (evalChecker initState solve) of
    Left _ -> False
    Right x -> x
  where c = (CNat 1)


solve :: (?globals :: Globals)
  => Checker Bool
solve = do
  cs <- State.get
 -- newConjunct
  pred <- popFromPredicateStack
  result <- liftIO $ provePredicate pred []
  case result of
    QED -> do
      traceM $ "yay!"
      return True
    _ -> do
      traceM $ "oh no!"
      return False
  where
    popFromPredicateStack = do
      st <- State.get
      return . head . predicateStack $ st


useCoeffect :: Coeffect -> Maybe Coeffect
useCoeffect (CNat n) = Just $ CNat (n - 1)
useCoeffect (CInterval (CNat n1) (CNat n2)) = Just $ CInterval (CNat (n1 `monus` 1)) (CNat (n2-1))
  where
    monus 0 x = 0
    monus x y = x - y
useCoeffect (CInfinity t) = Just $ CInfinity t
useCoeffect _ = Nothing


--- Replace with SMT solver constraints
checkSubUsage :: Coeffect -> Bool
checkSubUsage (CNat n1) = not (canUse $ CNat n1)
checkSubUsage (CInterval (CNat n1) _) = n1 == 0
checkSubUsage (CInfinity _) = True
checkSubUsage _ = False

checkAddUsage :: Coeffect -> Coeffect -> Bool
checkAddUsage (CNat n1) (CNat n2) = n1 == n2
checkAddUsage (CInterval (CNat n1) (CNat n2)) (CInterval (CNat n1') (CNat n2')) =
  n1 >= n1' && n2 <= n2' && n1 <= n2 && n1' <= n2'
checkAddUsage (CInfinity t1) (CInfinity t2) = t1 == t2
checkAddUsage _ _ = False


gradeAdd :: Coeffect -> Coeffect -> Maybe Coeffect
gradeAdd (CNat n) (CNat n') = Just $ CNat (n + n')
gradeAdd (CInterval (CNat n1) (CNat n2)) (CInterval (CNat n1') (CNat n2')) =
  let (n3, n4) = (n1 + n1', n2 + n2') in
  Just $ CInterval (CNat n3) (CNat n4)
gradeAdd (CInfinity t1) (CInfinity t2) = Just $ CInfinity t1
gradeAdd _ _ = Nothing

gradeSub :: Coeffect -> Coeffect -> Maybe Coeffect
gradeSub (CNat n) (CNat n') = if n - n' < 0 then Nothing else Just $ CNat (n - n')
gradeSub (CInterval (CNat n1) (CNat n2)) (CInterval (CNat n1') (CNat n2')) =
  let (n3, n4) = if n1' == 0 then
        (n2 - n2', n2 - n2')
        else
        (n1 - n1', n2 - n2') in
    case (n3<0, n4<0) of
      (True, False)-> Just $ (CInterval (CNat 0) (CNat n4))
      (False, False)-> Just $ (CInterval (CNat n3) (CNat n4))
      _ -> Nothing
gradeSub (CInfinity t1) (CInfinity t2) = Just (CInfinity t1)
gradeSub _ _ = Nothing

gradeMult :: Coeffect -> Coeffect -> Maybe Coeffect
gradeMult (CNat n) (CNat n') = Just $ CNat (n * n')
gradeMult (CInterval (CNat n1) (CNat n2)) (CInterval (CNat n1') (CNat n2')) =
  let (n3, n4) =
        (n1 * n1', n2 * n2') in
    Just $ (CInterval (CNat n3) (CNat n4))
gradeMult (CInfinity t1) (CInfinity t2) = Just $ CInfinity t1
gradeMult _ _ = Nothing

ctxSubtract :: Ctxt (Assumption)  -> Ctxt (Assumption) -> Maybe (Ctxt (Assumption))
ctxSubtract [] [] = Just []
ctxSubtract ((x1, Linear t1):xs) ys =
  case lookup x1 ys of
    Just _ -> ctxSubtract xs ys
    _ -> do
      ctx <- ctxSubtract xs ys
      return $ (x1, Linear t1) : ctx
ctxSubtract ((x1, Discharged t1 g1):xs) ys  =
  case lookup x1 ys of
    Just (Discharged t2 g2) ->
      case gradeSub g1 g2 of
        Just g3 -> do
          ctx <- ctxSubtract xs ys
          return $ (x1, Discharged t1 g3):ctx
        Nothing -> Nothing
    _ -> do
      ctx <- ctxSubtract xs ys
      return $ (x1, Discharged t1 g1):ctx
ctxSubtract _ _ = Just []

ctxMultByCoeffect :: Ctxt (Assumption) -> Coeffect -> Maybe (Ctxt (Assumption))
ctxMultByCoeffect [] _ = Just []
ctxMultByCoeffect ((x, Discharged t1 g1):xs) g2 =
  case gradeMult g1 g2 of
    Just g3 -> do
      ctxt <- ctxMultByCoeffect xs g2
      return $ ((x, Discharged t1 g3): ctxt)
    Nothing -> Nothing
ctxMultByCoeffect _ _ = Nothing

gradeLub :: Coeffect -> Coeffect -> Maybe Coeffect
gradeLub (CInterval (CNat g1) (CNat g2)) (CInterval (CNat g1') (CNat g2')) =
  Just (CInterval (CNat (min g1 g1')) (CNat (max g2 g2')))
gradeLub (CNat n) (CNat n') = if n == n' then Just (CNat n) else Nothing
gradeLub (CInfinity t1) (CInfinity t2) = Just (CInfinity t1)
gradeLub _ _ = Nothing

gradeGlb :: Coeffect -> Coeffect -> Maybe Coeffect
gradeGlb (CInterval (CNat g1) (CNat g2)) (CInterval (CNat g1') (CNat g2')) = Just (CInterval (CNat (max g1 g1')) (CNat (min g2 g2')))
gradeGlb (CNat n) (CNat n') = if n == n' then Just (CNat n) else Nothing
gradeGlb (CInfinity t1) (CInfinity t2) = Just $ CInfinity t1
gradeGlb _ _ = Nothing

ctxGlb :: Ctxt (Assumption) -> Ctxt (Assumption) -> Maybe (Ctxt (Assumption))
ctxGlb [] [] = Just []
ctxGlb x [] = Just x
ctxGlb [] y = Just y
ctxGlb ((x, Discharged t1 g1):xs) ys =
  case lookupAndCutout x ys of
    Just (ys', Discharged t2 g2) ->
      if t1 == t2 then
        case gradeGlb g1 g2 of
          Just g3 -> do
            ctx <- ctxGlb xs ys'
            return $ (x, Discharged t1 g3) : ctx
          Nothing -> Nothing
      else
        Nothing
    Nothing -> do
      ctx <- ctxGlb xs ys
      return $ (x, Discharged t1 g1) : ctx
    _ -> Nothing
ctxGlb ((x, Linear t1):xs) ys =
  case lookup x ys of
    Just (Linear t2) -> ctxGlb xs ys
    Nothing -> Nothing
    _ -> Nothing

ctxLub :: Ctxt (Assumption) -> Ctxt (Assumption) -> Maybe (Ctxt (Assumption))
ctxLub [] [] = Just []
ctxLub x [] = Just x
ctxLub [] y = Just y
ctxLub ((x, Discharged t1 g1):xs) ys =
  case lookupAndCutout x ys of
    Just (ys', Discharged t2 g2) ->
      if t1 == t2 then
        case gradeLub g1 g2 of
          Just g3 -> do
            ctx <- ctxLub xs ys'
            return $ (x, Discharged t1 g3) : ctx
          Nothing -> Nothing
      else
        Nothing
    Nothing -> do
      ctx <- ctxLub xs ys
      return $ (x, Discharged t1 g1) : ctx
    _ -> Nothing
ctxLub ((x, Linear t1):xs) ys =
  case lookup x ys of
    Just (Linear t2) -> ctxLub xs ys
    Nothing -> Nothing
    _ -> Nothing

checkCtxApproximation :: Ctxt (Assumption) -> Ctxt (Assumption) -> Maybe (Ctxt (Assumption))
checkCtxApproximation [] _ = return []
checkCtxApproximation ((x, Discharged t1 g1):xs) ys =
  case lookup x ys of
    Just (Discharged t2 g2) ->
        if g1 <= g2 then do
            ctxt <- checkCtxApproximation xs ys
            return $ (x, Discharged t1 g1) : ctxt
        else Nothing
    _ -> Nothing
checkCtxApproximation _ ys = Nothing

computeAddInputCtx :: Ctxt (Assumption) -> Ctxt (Assumption) -> Ctxt (Assumption)
computeAddInputCtx gamma delta =
  case ctxSubtract gamma delta of
    Just ctx' -> ctx'
    Nothing -> []

computeAddOutputCtx :: Ctxt (Assumption) -> Ctxt (Assumption) -> Ctxt (Assumption) -> Ctxt (Assumption)
computeAddOutputCtx del1 del2 del3 = do
  case addDeltas del1 del2 of
    Just del' ->
      case addDeltas del' del3 of
          Just del'' -> del''
          _ -> []
    _ -> []
  where
  addDeltas [] [] = Just []
  addDeltas x [] = Just x
  addDeltas [] y = Just y
  addDeltas ((x, Discharged t1 g1):xs) ys =
    case lookupAndCutout x ys of
      Just (ys', Discharged t2 g2) ->
        case gradeAdd g1 g2 of
          Just g3 -> do
            ctxt <- addDeltas xs ys'
            return $ (x, Discharged t1 g3) : ctxt
          Nothing -> Nothing
      Nothing -> do
        ctxt <- addDeltas xs ys
        return $ (x, Discharged t1 g1) : ctxt
      _ -> Nothing
  addDeltas ((x, Linear t1):xs) ys =
    case lookup x ys of
      Just (Linear t2) -> addDeltas xs ys
      Nothing -> do
        ctxt <- addDeltas xs ys
        return $ (x, Linear t1) : ctxt
      _ -> Nothing

pattern ProdTy t1 t2 = TyApp (TyApp (TyCon (Id "," ",")) t1) t2
pattern SumTy t1 t2  = TyApp (TyApp (TyCon (Id "Either" "Either")) t1) t2

isRAsync :: Type -> Bool
isRAsync (FunTy {}) = True
isRAsync _ = False

isLAsync :: Type -> Bool
isLAsync (ProdTy{}) = True -- ProdTy
isLAsync (SumTy{}) = True
isLAsync (Box{}) = True
isLAsync _ = False

isAtomic :: Type -> Bool
isAtomic (FunTy {}) = False
isAtomic (ProdTy{}) = False -- ProdTy
isAtomic (SumTy {}) = False
isAtomic (Box{}) = False
isAtomic _ = True

newtype Synthesiser a = Synthesiser
  { unSynthesiser :: ExceptT (NonEmpty CheckerError) (StateT CheckerState (ListT IO)) a }
  deriving (Functor, Applicative, Monad)
conv :: Checker a -> Synthesiser a
conv (Checker k) =  Synthesiser (ExceptT (StateT (\s -> ListT (fmap (\x -> [x]) $ runStateT (runExceptT k) s))))

tryAll :: Synthesiser a -> Synthesiser a -> Synthesiser a
tryAll m n =
  Synthesiser (ExceptT (StateT (\s -> mplus (runStateT (runExceptT (unSynthesiser n)) s) (runStateT (runExceptT (unSynthesiser m)) s))))

try :: Synthesiser a -> Synthesiser a -> Synthesiser a
try m n = tryAll m n

none :: Synthesiser a
none = Synthesiser (ExceptT (StateT (\s -> (ListT $ return []))))


testGlobals :: Globals
testGlobals = mempty
  { globalsNoColors = Just True
  , globalsSuppressInfos = Just True
  , globalsTesting = Just True
  }

-- ADTs available in synthesis (Either)
initDecls :: Ctxt (DataDecl)
initDecls =
  [
    (Id "Either" "Either", DataDecl
    {
      dataDeclSpan = nullSpanNoFile,
      dataDeclId = Id "Either" "Either",
      dataDeclTyVarCtxt = [((Id "a" "a"), KType),((Id "b" "b"), KType)],
      dataDeclKindAnn = Nothing,
      dataDeclDataConstrs =
        [
          DataConstrNonIndexed
          {
            dataConstrSpan = nullSpanNoFile,
            dataConstrId = (Id "Left" "Left"),
            dataConstrParams = [TyVar (Id "a" "a")]
          },
          DataConstrNonIndexed
          {
            dataConstrSpan = nullSpanNoFile,
            dataConstrId = (Id "Right" "Right"),
            dataConstrParams = [TyVar (Id "b" "b")]
          }
        ]
    })
  ]


testSyn :: Bool -> IO ()
testSyn useReprint =
  let ty =
  --      FunTy Nothing (Box (CNat 3) (TyVar $ mkId "a")) (FunTy Nothing (Box (CNat 6) (TyVar $ mkId "b") ) (Box (CNat 3) (ProdTy (ProdTy (TyVar $ mkId "b") (TyVar $ mkId "b")) (TyVar $ mkId "a")) ))
--        FunTy Nothing (Box (CNat 2) (TyVar $ mkId "a")) (ProdTy (TyVar $ mkId "a") (TyVar $ mkId "a"))
        FunTy Nothing (FunTy Nothing (TyVar $ mkId "a") (FunTy Nothing (TyVar $ mkId "b") (TyVar $ mkId "c"))) (FunTy Nothing (TyVar $ mkId "b") (FunTy Nothing (TyVar $ mkId "a") (TyVar $ mkId "c")))
--        FunTy Nothing (TyVar $ mkId "a") (TyVar $ mkId "a")
        in
    let ts = (Forall nullSpanNoFile [(mkId "a", KType), (mkId "b", KType), (mkId "c", KType)] [] ty) in
    let ?globals = testGlobals in do
    let res = testOutput $ topLevel ts in -- [(mkId "y", Linear (TyVar $ mkId "b")), (mkId "x", Linear (TyVar $ mkId "a"))] [] ty
        if length res == 0
        then  (putStrLn "No inhabitants found.")
        else  (forM_ res (\(ast, _, sub) -> putStrLn $
                           (if useReprint then pretty (reprintAsDef (mkId "f") ts ast) else pretty ast) ++ "\n" ++ (show sub) ))

testOutput :: Synthesiser (Expr () Type, Ctxt (Assumption), Substitution) -> [(Expr () Type, Ctxt (Assumption), Substitution)]
testOutput res =
  getList $ unsafePerformIO $ runListT $ evalStateT (runExceptT (unSynthesiser res)) initState

getList :: [Either (NonEmpty CheckerError) (Expr () Type, Ctxt Assumption, Substitution)] -> [(Expr () Type, Ctxt Assumption, Substitution)]
getList [] = []
getList (x:xs) = case x of
  Right x' -> x' : (getList xs)
  Left _ -> getList xs


topLevel :: (?globals :: Globals) => TypeScheme -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
topLevel ts@(Forall _ binders constraints ty) = do
  synthesise initDecls True False [] [] ts

-- Reprint Expr as a top-level declaration
reprintAsDef :: Id -> TypeScheme -> Expr () Type -> Def () Type
reprintAsDef id goalTy expr =
  Def
  { defSpan = nullSpanNoFile,
    defId = id,
    defRefactored = False,
    defEquations =
       EquationList
        { equationsSpan = nullSpanNoFile,
          equationsId = id,
          equationsRefactored = False,
          equations =
          [ Equation
            { equationSpan = nullSpanNoFile,
              equationAnnotation = TyVar $ mkId "a",
              equationPatterns = exprPatterns expr
              ,
            equationBody = exprBody expr
            }
          ]
        }
      ,
   defTypeScheme = goalTy
  }
  where

    exprPatterns (App _ _ _ (Val _ (Box{}) _ (Abs _ p _ e )) _) =
      p : (exprPatterns e)
    exprPatterns (Val _ (FunTy _ Box{} _) _ (Abs _ p _ e)) = exprPatterns e
    exprPatterns (Val _ _ _ (Abs _ p _ e)) = p : (exprPatterns e)
    exprPatterns e = []

    exprBody (App _ _ _ (Val _ _ _ (Abs _ _ _ e )) _) = exprBody e
    exprBody (Val _ _ _ (Abs _ _ _ e)) = exprBody e
    exprBody e = e


bindToContext :: (Id, Assumption) -> Ctxt (Assumption) -> Ctxt (Assumption) -> Bool -> (Ctxt (Assumption), Ctxt (Assumption))
bindToContext var gamma omega True = (gamma, var:omega)
bindToContext var gamma omega False = (var:gamma, omega)

useVar :: (Id, Assumption) -> Ctxt (Assumption) -> Bool -> (Bool, Ctxt (Assumption), Type)
useVar (name, Linear t) gamma False = (True, gamma, t)
useVar (name, Discharged t grade) gamma False =
    if canUse grade then
      case useCoeffect grade of
        Nothing -> (False, [], t )
        Just grade' ->
          (True, (name, Discharged t grade'):gamma, t)
    else
        (False, [], t)
useVar (name, Linear t) _ True = (True, [(name, Linear t)], t)
useVar (name, Discharged t grade) _ True =
    if canUse grade then
      case useCoeffect grade of
        Nothing -> (False, [], t)
        Just grade' ->
          let singleUse = gradeSub grade grade' in
            case singleUse of
              Just grade'' -> (True, [(name, Discharged t grade'')], t)
              Nothing -> (False, [], t)
    else
        (False, [], t)

makeVar :: Id -> TypeScheme -> Expr () Type
makeVar name (Forall _ _ _ t) =
  Val s t False (Var t name)
  where s = nullSpanNoFile

makeAbs :: Id -> Expr () Type -> TypeScheme -> Expr () Type
makeAbs name e (Forall _ _ _ t@(FunTy Nothing t1 t2)) =
  Val s t False (Abs t (PVar s t False name) (Just t1) e)
  where s = nullSpanNoFile

makeApp :: Id -> Expr () Type -> TypeScheme -> Type -> Expr () Type
makeApp name e (Forall _ _ _ t1) t2 =
  App s t1 False (makeVar name (Forall nullSpanNoFile [] [] t2)) e
  where s = nullSpanNoFile

makeBox :: TypeScheme -> Expr () Type -> Expr () Type
makeBox (Forall _ _ _ t) e =
  Val s t False (Promote t e)
  where s = nullSpanNoFile

makeUnbox :: Id -> Id -> TypeScheme -> Type -> Type -> Expr () Type -> Expr () Type
makeUnbox name1 name2 (Forall _ _ _ goalTy) boxTy varTy e  =
  App s goalTy False
  (Val s boxTy False
    (Abs (FunTy Nothing boxTy goalTy)
      (PBox s varTy False
        (PVar s varTy False name1)) (Just varTy) e))
  (Val s varTy False
    (Var varTy name2))
  where s = nullSpanNoFile

makePair :: Type -> Type -> Expr () Type -> Expr () Type -> Expr () Type
makePair lTy rTy e1 e2 =
  App s rTy False (App s lTy False (Val s (ProdTy lTy rTy) False (Constr (ProdTy lTy rTy) (mkId ",") [])) e1) e2
  where s = nullSpanNoFile

makePairElim :: Id -> Id -> Id -> TypeScheme -> Type -> Type -> Expr () Type -> Expr () Type
makePairElim name lId rId (Forall _ _ _ goalTy) lTy rTy e =
  App s goalTy False
  (Val s (ProdTy lTy rTy) False
    (Abs (FunTy Nothing (ProdTy lTy rTy) goalTy)
      (PConstr s (ProdTy lTy rTy) False name [(PVar s lTy False lId), (PVar s rTy False rId)] )
        Nothing e))
  (Val s (ProdTy lTy rTy) False (Var (ProdTy lTy rTy) name))
  where s = nullSpanNoFile

makeEitherLeft :: Type -> Type -> Expr () Type -> Expr () Type
makeEitherLeft lTy rTy e  =
  (App s lTy False (Val s (SumTy lTy rTy) False (Constr (SumTy lTy rTy) (mkId "Left") [])) e)
  where s = nullSpanNoFile

makeEitherRight :: Type -> Type -> Expr () Type -> Expr () Type
makeEitherRight lTy rTy e  =
  (App s rTy False (Val s (SumTy lTy rTy) False (Constr (SumTy lTy rTy) (mkId "Right") [])) e)
  where s = nullSpanNoFile


--makeEitherCase :: Id -> Id -> Id -> TypeScheme -> Type -> Type -> Expr () Type
--makeEitherCase name lId rId (Forall _ _ _ goalTy) lTy rTy =

 
varHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> Bool
  -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
varHelper decls left [] _ _ = none
varHelper decls left (var@(x, a) : right) isAdd goalTy =
  (varHelper decls (var:left) right isAdd goalTy) `try`
  let (canUse, gamma, t) = useVar var (left ++ right) isAdd in
    if canUse then
      case goalTy of
        Forall _ binders constraints goalTy' ->
          do
            (success, specTy, subst) <- conv $ equalTypes nullSpanNoFile t goalTy'
            case success of
              True -> do
                return (makeVar x goalTy, gamma, subst)
              _ -> none
    else
      none

absHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> Bool
  -> Bool
  -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
absHelper decls gamma omega allowLam isAdd goalTy =
  case goalTy of
      (Forall _ binders constraints (FunTy _ t1 t2)) -> do
        x <- conv $ freshIdentifierBase "x"
        let id = mkId x
        let (gamma', omega') =
              if isLAsync t1 then
                (gamma, ((id, Linear t1):omega))
              else
                (((id, Linear t1):gamma, omega))
        (e, delta, subst) <- synthesise decls True isAdd gamma' omega' (Forall nullSpanNoFile binders constraints t2)
        case (isAdd, lookupAndCutout id delta) of
          (True, Just (delta', Linear _)) ->
            return (makeAbs id e goalTy, delta', subst)
          (False, Nothing) ->
            return (makeAbs id e goalTy, delta, subst)
          _ -> none
      _ -> none


appHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> Bool -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
appHelper decls left [] _ _ = none
appHelper decls left (var@(x, a) : right) False goalTy@(Forall _ binders constraints _ ) =
  (appHelper decls (var : left) right False goalTy) `try`
  let omega = left ++ right in
  let (canUse, omega', t) = useVar var omega False in
  case (canUse, t) of
    (True, FunTy _ t1 t2) -> do
        id <- conv $ freshIdentifierBase "x"
        let id' = mkId id
        let (gamma', omega'') = bindToContext (id', Linear t2) omega' [] (isLAsync t2)
        (e1, delta1, sub1) <- synthesise decls True False gamma' omega'' goalTy
        (e2, delta2, sub2) <- synthesise decls True False delta1 [] (Forall nullSpanNoFile binders constraints t1)
        subst <- conv $ combineSubstitutions nullSpanNoFile sub1 sub2
        case lookup id' delta2 of
          Nothing ->
            return (Language.Granule.Syntax.Expr.subst (makeApp x e2 goalTy t) id' e1, delta2, subst)
          _ -> none
    _ -> none
appHelper decls left (var@(x, a) : right) True goalTy@(Forall _ binders constraints _ ) =
  (appHelper decls (var : left) right True goalTy) `try`
  let omega = left ++ right in
  let (canUse, omega', t) = useVar var omega True in
    case (canUse, t) of
      (True, FunTy _ t1 t2) -> do
        id <- conv $ freshIdentifierBase "x"
        let id' = mkId id
        let gamma1 = computeAddInputCtx omega omega'
        let (gamma1', omega'') = bindToContext (id', Linear t2) gamma1 [] (isLAsync t2)
        (e1, delta1, sub1) <- synthesise decls True True gamma1' omega'' goalTy

        let gamma2 = computeAddInputCtx gamma1' delta1
        (e2, delta2, sub2) <- synthesise decls True True gamma2 [] (Forall nullSpanNoFile binders constraints t1)

        let delta3 = computeAddOutputCtx omega' delta1 delta2
        subst <- conv $ combineSubstitutions nullSpan sub1 sub2
        case lookupAndCutout id' delta3 of
          Just (delta3', Linear _) ->
                return (Language.Granule.Syntax.Expr.subst (makeApp x e2 goalTy t) id' e1, delta3', subst)
          _ -> none
      _ -> none


boxHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> Bool
  -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
boxHelper decls gamma isAdd goalTy =
  case goalTy of
    (Forall _ binders constraints (Box g t)) -> do
      (e, delta, subst) <- synthesise decls True isAdd gamma [] (Forall nullSpanNoFile binders constraints t)
      if isAdd then
        case ctxMultByCoeffect delta g of
          Just delta' -> do
            return (makeBox goalTy e, delta', subst)
          _ -> none
      else
        let used = ctxSubtract gamma delta in
        -- Compute what was used to synth e
          case used of
            Just used' -> do
              case ctxMultByCoeffect used' g of
                Just delta' -> do
                  case ctxSubtract gamma delta' of
                    Just delta'' -> do
                      return (makeBox goalTy e, delta'', subst)
                    Nothing -> none
                _ -> none
            _ -> none
    _ -> none


unboxHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> Bool
  -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
unboxHelper decls left [] _ _ _ = none
unboxHelper decls left (var@(x, a) : right) gamma False goalTy =
    let omega = left ++ right in
    let (canUse, omega', t) = useVar var omega False in
      case (canUse, t) of
        (True, Box grade t') -> do
          id <- conv $ freshIdentifierBase "x"
          let id' = mkId id
          let (gamma', omega'') = bindToContext (id', Discharged t' grade) gamma omega' (isLAsync t')
          (e, delta, subst) <- synthesise decls True False gamma' omega'' goalTy
          case lookupAndCutout id' delta of
            Just (delta', (Discharged _ usage)) -> do
              conv $ addConstraint (ApproximatedBy nullSpanNoFile usage (CZero $ zero usage ) (zero usage))
              res <- conv $ solve
              case res of
                True ->
                  return (makeUnbox id' x goalTy t t' e, delta', subst)
                False -> none
            _ -> none
        _ -> none
    `try `(unboxHelper decls (var : left) right gamma False goalTy)
unboxHelper decls left (var@(x, a) : right) gamma True goalTy =
    (unboxHelper decls (var : left) right gamma True goalTy) `try`
    let omega = left ++ right in
    let (canUse, omega', t) = useVar var omega True in
      case (canUse, t) of
        (True, Box grade t') -> do
           id <- conv $ freshIdentifierBase "x"
           let id' = mkId id
           let omega1 = computeAddInputCtx omega omega'
           let (gamma', omega1') = bindToContext (id', Discharged t' grade) gamma omega1 (isLAsync t')
           (e, delta, subst) <- synthesise decls True True gamma' omega1' goalTy
           let delta' = computeAddOutputCtx omega' delta []
           case lookupAndCutout id' delta' of
             Just (delta'', (Discharged _ usage)) -> do
               conv $ addConstraint (Eq nullSpanNoFile grade usage (TyVar $ mkId "a")) -- checkAddUsage usage grade
               res <- conv $ solve
               case res of
                 True ->
                   return (makeUnbox id' x goalTy t t' e,  delta'', subst)
                 False -> none
             _ -> do
               conv $ addConstraint (ApproximatedBy nullSpanNoFile grade (CZero $ zero grade) (zero grade)) -- zeroUse grade
               res <- conv $ solve
               case res of
                 True ->
                   return (makeUnbox id' x goalTy t t' e,  delta', subst)
                 False -> none
        _ -> none


pairElimHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> Bool
  -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
pairElimHelper decls left [] _ _ _ = none
pairElimHelper decls left (var@(x, a):right) gamma False goalTy =
  (pairElimHelper decls (var:left) right gamma False goalTy) `try`
  let omega = left ++ right in
  let (canUse, omega', t) = useVar var omega False in
    case (canUse, t) of
      (True, ProdTy t1 t2) -> do
          l <- conv $ freshIdentifierBase "x"
          r <- conv $ freshIdentifierBase "x"
          let (lId, rId) = (mkId l, mkId r)
          let (gamma', omega'') = bindToContext (lId, Linear t1) gamma omega' (isLAsync t1)
          let (gamma'', omega''') = bindToContext (rId, Linear t2) gamma' omega'' (isLAsync t2)
          (e, delta, subst) <- synthesise decls True False gamma'' omega''' goalTy
          case (lookup lId delta, lookup rId delta) of
            (Nothing, Nothing) -> return (makePairElim x lId rId goalTy t1 t2 e, delta, subst)
            _ -> none
      _ -> none
pairElimHelper decls left (var@(x, a):right) gamma True goalTy =
  (pairElimHelper decls (var:left) right gamma True goalTy) `try`
  let omega = left ++ right in
  let (canUse, omega', t) = useVar var omega True in
    case (canUse, t) of
      (True, ProdTy t1 t2) -> do
          l <- conv $ freshIdentifierBase "x"
          r <- conv $ freshIdentifierBase "x"
          let (lId, rId) = (mkId l, mkId r)
          let omega1 = computeAddInputCtx omega omega'
          let (gamma', omega1') = bindToContext (lId, Linear t1) gamma omega1 (isLAsync t1)
          let (gamma'', omega1'') = bindToContext (rId, Linear t2) gamma' omega1' (isLAsync t2)
          (e, delta, subst) <- synthesise decls True True gamma'' omega1'' goalTy
          let delta' = computeAddOutputCtx omega' delta []
          case lookupAndCutout lId delta' of
            Just (delta', Linear _) ->
              case lookupAndCutout rId delta' of
                Just (delta''', Linear _) -> return (makePairElim x lId rId goalTy t1 t2 e, delta''', subst)
                _ -> none
            _ -> none
      _ -> none

pairIntroHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> Bool
  -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
pairIntroHelper decls gamma isAdd goalTy =
  case goalTy of
    (Forall _ binders constraints (ProdTy t1 t2)) -> do
      (e1, delta1, subst1) <- synthesise decls True isAdd gamma [] (Forall nullSpanNoFile binders constraints t1)
      let gamma2 = if isAdd then computeAddInputCtx gamma delta1 else delta1
      (e2, delta2, subst2) <- synthesise decls True isAdd gamma2 [] (Forall nullSpanNoFile binders constraints t2)
      let delta3 = if isAdd then computeAddOutputCtx delta1 delta2 [] else delta2
      subst <- conv $ combineSubstitutions nullSpanNoFile subst1 subst2
      return (makePair t1 t2 e1 e2, delta3, subst)
    _ -> none


sumIntroHelper :: (?globals :: Globals)
  => Ctxt (DataDecl) -> Ctxt (Assumption) -> Bool -> TypeScheme -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
sumIntroHelper decls gamma isAdd goalTy =
  case goalTy of
    (Forall _ binders constraints (SumTy t1 t2)) -> do
      try
        (do
            (e1, delta1, subst1) <- synthesise decls True isAdd gamma [] (Forall nullSpanNoFile binders constraints t1)
            return (makeEitherLeft t1 t2 e1, delta1, subst1)

        )
        (do
            (e2, delta2, subst2) <- synthesise decls True isAdd gamma [] (Forall nullSpanNoFile binders constraints t2)
            return (makeEitherRight t1 t2 e2, delta2, subst2)

        )
    _ -> none

{--
sumElimHelper :: (?configuration :: Configuration)
  => Context -> Context -> Context -> Bool -> Type -> StateT Int [] (Expr PCF, Context, Substitution)
sumElimHelper left [] _ _ _ = none
sumElimHelper left (var@(x, a):right) gamma False goalTy =
  (sumElimHelper (var:left) right gamma False goalTy) `try`
  let omega = left ++ right in
  let (canUse, omega', t) = useVar var omega False in
    case (canUse, t) of
      (True, SumTy t1 t2) -> do
        l <- freshVar "x"
        r <- freshVar "x"
        let (gamma', omega'') = bindToContext (l, Linear t1) gamma omega' (isLAsync t1)
        let (gamma'', omega''') = bindToContext (r, Linear t2) gamma' omega'' (isLAsync t2)
        (e1, delta1, subst1) <- synthesise True False gamma' omega'' goalTy
        (e2, delta2, subst2) <- synthesise True False gamma'' omega''' goalTy
        let subst = combineSubstitutions subst1 subst2
        case subst of
          Just subst' ->
            case (lookup l delta1, lookup r delta2) of
              (Nothing, Nothing) ->
                case ctxGlb delta1 delta2 of
                  Just delta3 ->
                    return (Ext (Case (Var x) (l, e1) (r, e2)), delta3, subst')
                  Nothing -> none
              _ -> none
          _ -> none
      _ -> none

sumElimHelper left (var@(x, a):right) gamma True goalTy =
  (sumElimHelper (var:left) right gamma True goalTy) `try`
  let omega = left ++ right in
  let (canUse, omega', t) = useVar var omega True in
    case (canUse, t) of
      (True, SumTy t1 t2) -> do
        l <- freshVar "x"
        r <- freshVar "x"
        let omega1 = computeAddInputCtx omega omega'
        let (gamma', omega1') = bindToContext (l, Linear t1) gamma omega1 (isLAsync t1)
        let (gamma'', omega1'') = bindToContext (r, Linear t2) gamma' omega1' (isLAsync t2)
        (e1, delta1, subst1) <- synthesise True True gamma' omega1' goalTy
        (e2, delta2, subst2) <- synthesise True True gamma'' omega1'' goalTy
        let subst = combineSubstitutions subst1 subst2
        case subst of
          Just subst' ->
            case (lookupAndCutout l delta1, lookupAndCutout r delta2) of
              (Just (delta1', Linear _), Just (delta2', Linear _)) ->
                case ctxLub delta1' delta2' of
                  Just delta3 ->
                    let delta3' = computeAddOutputCtx omega' delta3 [] in do
                      traceM $ show delta3'
                      return (Ext (Case (Var x) (l, e1) (r, e2)), delta3', subst')
                  Nothing -> do
                    none
              _ -> do
                none
          _ -> none
      _ -> none
--}

synthesise :: (?globals :: Globals)
           => Ctxt (DataDecl)      -- ADT Definitions
           -> Bool                 -- whether a function is allowed at this point
           -> Bool                 -- whether the synthesis is in additive mode or not
           -> Ctxt (Assumption)    -- (unfocused) free variables
           -> Ctxt (Assumption)    -- focused variables
           -> TypeScheme           -- type from which to synthesise
           -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)

synthesise decls allowLam isAdd gamma omega goalTy@(Forall _ binders _ goalTy') = do
  conv $ State.modify (\st -> st { tyVarContext = map (\(n, c) -> (n, (c, ForallQ))) binders})
  case (isRAsync goalTy', omega) of
    (True, omega) ->
      -- Right Async : Decompose goalTy until synchronous
      absHelper decls gamma omega allowLam isAdd goalTy `try` none
    (False, omega@(x:xs)) ->
      -- Left Async : Decompose assumptions until they are synchronous (eliminators on assumptions)
      unboxHelper decls [] omega gamma isAdd goalTy
      `try`
      pairElimHelper decls [] omega gamma isAdd goalTy
    (False, []) ->
      -- Transition to synchronous (focused) search
      if isAtomic goalTy' then
        -- Left Sync: App rule + Init rules
        varHelper decls [] gamma isAdd goalTy
        `try`
        appHelper decls [] gamma isAdd goalTy
      else
        -- Right Sync : Focus on goalTy
        pairIntroHelper decls gamma isAdd goalTy
        `try`
        boxHelper decls gamma isAdd goalTy