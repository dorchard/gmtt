module Language.Granule.Interpreter.HeapModel where

import Language.Granule.Syntax.Def
import Language.Granule.Syntax.Expr
import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Type
import Language.Granule.Syntax.Pattern
import Language.Granule.Syntax.Pretty
import Language.Granule.Syntax.Span
import Language.Granule.Context
import Language.Granule.Utils

import Control.Monad.State

-- Some type alises
type Val   = Value () ()
type Grade = Type
-- Heap map
type Heap = Ctxt (Grade, Expr () ())
  -- Ctxt (Grade, (Ctxt Type, Expr () (), Type))

-- Stubs
heapEval :: AST () () -> IO (Maybe Val)
heapEval _ = return Nothing

heapEvalDefs :: [Def () ()] -> Id -> IO (Ctxt Val)
heapEvalDefs defs defName = return []


-- (\([x] : Int [2]) -> x)
-- Key hook in for now
heapEvalJustExprAndReport :: (?globals :: Globals) => Expr () () -> Maybe String
heapEvalJustExprAndReport e =
    Just (concatMap report res)
  where
    res = evalState (heapEvalJustExpr e) 0
    report (expr, (heap, grades, inner)) =
        "Expr = " ++ pretty expr
       ++ "\n Heap = " ++ prettyHeap heap
       ++ "\n Output grades = " ++ pretty grades
       ++ "\n Embedded context = " ++ pretty inner
       ++ "\n"
    prettyHeap = pretty

heapEvalJustExpr :: Expr () () -> State Integer [(Expr () (), (Heap, Ctxt Grade, Ctxt Grade))]
heapEvalJustExpr e@(Val _ _ _ (Abs _ (PBox _ _ _ (PVar _ _ _ v)) (Just (Box r a)) _)) =
  smallHeapRedux heap e' (TyGrade Nothing 1)
   where
    (heap, e') = buildInitialHeap e

heapEvalJustExpr _ = return []

buildInitialHeap :: Expr () () -> (Heap, Expr () ())
buildInitialHeap (Val _ _ _ (Abs _ (PBox _ _ _ (PVar _ _ _ v)) (Just (Box r a)) e)) = 
    (h0 : heap, e')
  where
     h0        = (v, (r, (Val nullSpanNoFile () False (Var () v))))
     (heap, e') = buildInitialHeap e

buildInitialHeap e = ([], e)

-- Functionalisation of the main small-step reduction relation
smallHeapRedux :: Heap -> Expr () () -> Grade -> State Integer [(Expr () (), (Heap, Ctxt Grade, Ctxt Grade))]

-- [Small-Var]
smallHeapRedux heap (Val _ _ _ (Var _ x)) r = do
  case lookupAndCutout x heap of
    Just (heap', (rq, aExpr)) ->
    --Just (heap', (rq, (gamma, aExpr, aType))) ->
      let
        gammaOut    = []
        resourceOut = [(x, r)]
        -- Represent (possibly undefined resource minus here)
        --heapHere    = (x, (TyInfix TyOpMinus rq r, (gamma, aExpr, aType)))
        heapHere    = (x, (TyInfix TyOpMinus rq r, aExpr))

      in return [(aExpr, (heapHere : heap', resourceOut , gammaOut))]

    -- Heap not well-formed
    Nothing -> return []

-- [Small-AppBeta] adapted to a Granule graded beta redux, e.g., (\[x] -> a) [b]
smallHeapRedux heap
    (App _ _ _ (Val _ _ _ (Abs _ (PVar _ _ _ y) (Just (Box q aType')) a)) (Val s _ _ (Promote _ b))) r = do
  -- fresh variable
  st <- get
  let x = mkId $ "x" ++ show st
  put $ st+1
  --
  let heap' = (x, (TyInfix TyOpTimes r q, b)) : heap
  return [(subst (Val s () False (Var () x)) y a, (heap' , ctxtMap (const (TyGrade Nothing 0)) heap, [(x , TyInfix TyOpTimes r q)]))]

-- [Small-AppL]
smallHeapRedux heap (App s a b e1 e2) r = do
  res <- smallHeapRedux heap e1 r
  return $ map (\(e1', (h, resourceOut, gammaOut)) -> (App s a b e1' e2, (h, resourceOut, gammaOut))) res

-- Catch all
smallHeapRedux heap e t =
  return []