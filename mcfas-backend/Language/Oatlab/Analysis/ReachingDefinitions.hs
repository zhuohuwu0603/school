{-|
Module      : Language.Oatlab.Analysis.ReachingDefinitions
Description : Reaching definitions analysis using McFAS
Copyright   : (c) Jacob Errington 2016
License     : MIT
Maintainer  : mcfas@mail.jerrington.me
Stability   : experimental

TODO use real chunks of AST instead of strings for representing the definitions.
-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}

module Language.Oatlab.Analysis.ReachingDefinitions
( reachingDefinitions
, initializeReachingDefinitions
, initializeReachingDefinitionsAlg
, reachingDefinitionsPpAlg
, ReachingDefinitionsP(..)
, ReachingDefinitionsApproxP(..)
, ReachingDefinitions
, ReachingDefinitionsApprox
) where

import Data.Annotation
import Data.HFunctor
import Data.Reflection
import Language.Common.Analysis
import Language.Oatlab.Analysis
import Language.Oatlab.Analysis.StatementNumbering
import Language.Oatlab.Syntax
import Language.Oatlab.Pretty

import Control.Monad.State
import Data.Proxy
import qualified Data.Map as M
import qualified Data.Set as S
import Text.PrettyPrint

import Debug.Trace

-- | Helper for adding a definition to the set of definitions associated with a
-- given expression.
addDefinition
  :: String
  -> StatementNumber
  -> M.Map String (S.Set StatementNumber)
  -> M.Map String (S.Set StatementNumber)
addDefinition s n = M.alter f s where
  f :: Maybe (S.Set StatementNumber) -> Maybe (S.Set StatementNumber)
  f = Just . S.insert n . maybe S.empty id

-- | Type-level function that says that statements are approximated with maps
-- from expressions (represented by strings) to sets of statement numbers
-- (their definiting statements), and that all other AST node are approximated
-- with trivial data.
type family ReachingDefinitionsApprox (node :: AstNode) :: * where
  ReachingDefinitionsApprox 'StatementNode
    = M.Map String (S.Set StatementNumber)
  ReachingDefinitionsApprox _ = ()

-- | The approximation used in the reaching definitions analysis.
--
-- Simulates the action of the type-level function 'ReachingDefinitionsApprox'.
newtype ReachingDefinitionsApproxP (node :: AstNode)
  = ReachingDefinitionsApproxP
    { unReachingDefinitionsApproxP :: ReachingDefinitionsApprox node
    }

-- | The annotation used in reaching definitions analysis.
data ReachingDefinitions (node :: AstNode)
  = ReachingDefinitions
    { rdRemainingIterations :: Int
    , rdApproximation :: ReachingDefinitionsApproxP node
    , rdStatementNumber :: StatementNumber
    }

deriving instance ReflectS a => Eq (ReachingDefinitions a)

-- | Annotate 'StatementNode' with 'ReachingDefinitions' and everything else
-- with a trivial annotation.
--
-- /Node annotation index interpretation/
type family ReachingDefinitionsP' (node :: AstNode) :: * where
  ReachingDefinitionsP' 'StatementNode = ReachingDefinitions 'StatementNode
  ReachingDefinitionsP' _ = ()

-- | Newtype simulation for 'ReachingDefinitionsP'.
newtype ReachingDefinitionsP (node :: AstNode)
  = ReachingDefinitionsP { unReachingDefinitionsP :: ReachingDefinitionsP' node }

instance ReflectS a => Eq (ReachingDefinitionsP a) where
  ReachingDefinitionsP x == ReachingDefinitionsP y = case reflectS (Proxy :: Proxy a) of
    ProgramDeclNodeS -> x == y
    TopLevelDeclNodeS -> x == y
    VarDeclNodeS -> x == y
    StatementNodeS -> x == y
    ExpressionNodeS -> x == y
    IdentifierNodeS -> x == y

instance ReflectS a => Eq (ReachingDefinitionsApproxP a) where
  ReachingDefinitionsApproxP x == ReachingDefinitionsApproxP y
    = case reflectS (Proxy :: Proxy a) of
      ProgramDeclNodeS -> x == y
      TopLevelDeclNodeS -> x == y
      VarDeclNodeS -> x == y
      StatementNodeS -> x == y
      ExpressionNodeS -> x == y
      IdentifierNodeS -> x == y

-- | Construct an initial reaching definitions annotation for statements.
initialReachingDefinitions :: StatementNumber -> ReachingDefinitions 'StatementNode
initialReachingDefinitions number
  = ReachingDefinitions
    { rdRemainingIterations = 100
    , rdApproximation = ReachingDefinitionsApproxP M.empty
    , rdStatementNumber = number
    }

-- | Replace any existing index-annotations on a tree with the initial state
-- for a reaching definitions analysis.
--
-- The input tree must have its statements numbered; see 'numberStatementAlg'.
--
-- /Higher-order F-algebra/
initializeReachingDefinitionsAlg
  :: IAnn StatementNumberingP OatlabAstF f
  :~> IAnn ReachingDefinitionsP OatlabAstF f
initializeReachingDefinitionsAlg = reannotate phi where
  phi
    :: forall (f :: AstNode -> *) (a :: AstNode).
    OatlabAstF f a
    -> StatementNumberingP a
    -> ReachingDefinitionsP a
  phi node a = ReachingDefinitionsP $ case collapseIndex node of
    StatementNodeS -> initialReachingDefinitions (unStatementNumberingP a)
    ProgramDeclNodeS -> ()
    TopLevelDeclNodeS -> ()
    VarDeclNodeS -> ()
    ExpressionNodeS -> ()
    IdentifierNodeS -> ()

-- | Annotate a bare syntax tree with the initial configuration for a reaching
-- definitions analysis.
--
-- /Monadic tree rewrite/
initializeReachingDefinitions
  :: forall (m :: * -> *) (a :: AstNode).
    (Monad m, MonadState Int m)
  => OatlabAst a
  -> m (OatlabIAnnAst ReachingDefinitionsP a)
initializeReachingDefinitions = unMonadH . hcata phi where
  phi
    :: OatlabAstF (MonadH m (OatlabIAnnAst ReachingDefinitionsP)) b
    -> MonadH m (OatlabIAnnAst ReachingDefinitionsP) b
  phi = MonadH
    . fmap HFix
    . join
    . fmap (sequenceH . initializeReachingDefinitionsAlg)
    . numberStatementAlg
    . IAnn (K ())

-- | The dataflow equations for the reaching definitions analysis.
--
-- * When a for-loop is encountered, it is considered to define its variable
-- * When an assignment is encounteded, it is considered to define its LHS
reachingDefinitionsDataflow
  :: forall (m :: * -> *) (a :: AstNode). (Monad m, ReflectS a)
  => IAnn ReachingDefinitionsP OatlabAstF (OatlabIAnnAst ReachingDefinitionsP) a
  -- ^ Node in the syntax tree
  -> ReachingDefinitionsApproxP a -- ^ input flow set
  -> m (ReachingDefinitionsApproxP a) -- ^ output flow set
reachingDefinitionsDataflow (IAnn a node) approx
  = pure $ case reflectS (Proxy :: Proxy a) of
    StatementNodeS ->
      let (ReachingDefinitionsP (ReachingDefinitions {..})) = a
      in case node of
        WhileLoop _ _ -> approx
        Branch _ _ _ -> approx
        Return _ -> approx
        ForLoop var _ _
          -> ReachingDefinitionsApproxP $
            addDefinition
              (nameFromVarDecl (stripI var))
              rdStatementNumber
              (unReachingDefinitionsApproxP rdApproximation)
        Assignment lhs _
          | unK (hcata (isLValueAlg . bareI) lhs)
            -> ReachingDefinitionsApproxP $
              M.insert
                (renderOatlab (unK $ hcata (ppAlg . bareI) lhs))
                (S.singleton rdStatementNumber)
                (unReachingDefinitionsApproxP rdApproximation)
        Assignment _ _ -> approx
          -- assignment to things that are not lvalues is technically an error
        Expression _ -> approx
    ProgramDeclNodeS -> approx
    TopLevelDeclNodeS -> approx
    VarDeclNodeS -> approx
    ExpressionNodeS -> approx
    IdentifierNodeS -> approx

-- | The reaching definitions analysis.
reachingDefinitions
  :: Monad m
  => OatlabAnalysis
    (OatlabIAnnAst ReachingDefinitionsP)
    ReachingDefinitionsP
    ReachingDefinitionsApproxP
    'StatementNode
    'StatementNode
    m
    'Forward
reachingDefinitions = Analysis
  { analysisMerge
    = \ (ReachingDefinitionsApproxP x :: ReachingDefinitionsApproxP a)
        (ReachingDefinitionsApproxP y :: ReachingDefinitionsApproxP a)
        -> pure $ ReachingDefinitionsApproxP $ case reflectS (Proxy :: Proxy a) of
          StatementNodeS -> M.unionWith S.union x y
          ProgramDeclNodeS -> ()
          TopLevelDeclNodeS -> ()
          VarDeclNodeS -> ()
          ExpressionNodeS -> ()
          IdentifierNodeS -> ()
  , analysisDataflow = reachingDefinitionsDataflow
  , analysisApproximationEq = (==)
  , analysisGetApproximation
    = \ (ReachingDefinitionsP a :: ReachingDefinitionsP a)
      -> case reflectS (Proxy :: Proxy a) of
          StatementNodeS -> rdApproximation a
          ProgramDeclNodeS -> ReachingDefinitionsApproxP ()
          TopLevelDeclNodeS -> ReachingDefinitionsApproxP ()
          VarDeclNodeS -> ReachingDefinitionsApproxP ()
          ExpressionNodeS -> ReachingDefinitionsApproxP ()
          IdentifierNodeS -> ReachingDefinitionsApproxP ()
  , analysisGetIterations
    = \ (ReachingDefinitionsP a) -> rdRemainingIterations a
  , analysisUpdateApproximation
    = \ approx
        (ReachingDefinitionsP a :: ReachingDefinitionsP node)
        -> pure . ReachingDefinitionsP $ case reflectS (Proxy :: Proxy node) of
          StatementNodeS
            -> a { rdApproximation = approx }
          ProgramDeclNodeS -> ()
          TopLevelDeclNodeS -> ()
          VarDeclNodeS -> ()
          ExpressionNodeS -> ()
          IdentifierNodeS -> ()
  , analysisUpdateIterations
    = \ f
        (ReachingDefinitionsP a)
        -> pure $ ReachingDefinitionsP $ a
          { rdRemainingIterations = f (rdRemainingIterations a)
          }
  , analysisBoundaryApproximation = pure (ReachingDefinitionsApproxP M.empty)
  }

reachingDefinitionsPpAlg
  :: IAnn ReachingDefinitionsP OatlabAstF (K Doc) :~> K Doc
reachingDefinitionsPpAlg (IAnn a node) = case collapseIndex node of
  StatementNodeS -> case a of
    ReachingDefinitionsP rd -> K $
      unK (ppAlg node) <+> "/*" <+> ppRd rd <+> "*/"
  _ -> ppAlg node

ppRd :: ReachingDefinitions 'StatementNode -> Doc
ppRd ReachingDefinitions {..} = "#" <> ppStmtNum rdStatementNumber <> rest where
  (ReachingDefinitionsApproxP approx) = rdApproximation
  defs = S.toList (S.unions (M.elems approx))
  ppDefs = hcat (punctuate ", " (ppStmtNum <$> defs))
  rest = if null defs then empty else " :" <+> ppDefs

ppStmtNum :: StatementNumber -> Doc
ppStmtNum (StatementNumber n) = int n
