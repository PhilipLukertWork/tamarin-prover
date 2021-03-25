{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE ViewPatterns               #-}
-- |
-- Copyright   : (c) 2010-2012 Benedikt Schmidt, Simon Meier
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Benedikt Schmidt <beschmi@gmail.com>
-- Portability : GHC only
--
-- Support for reasoning with and about disjunctions of substitutions.
module Theory.Tools.EquationStore (
  -- * Equations
    SplitId(..)
  , StoreEntry(..)

  , EqStore(..)
  , emptyEqStore
  , eqsSubst
  , eqsConj

  -- ** Equalitiy constraint conjunctions
  , falseEqConstrConj

  -- ** Queries
  , eqsIsFalse
  , rawSubtermRel


  -- ** Adding equalities
  , addEqs
  , addSubterm
  , addRuleVariants
  , addEntries

  -- ** Case splitting
  , performSplit
  , dropNameHintsBound

  , splits
  , splitSize
  , splitExists

  -- * Simplification
  , simp
  , simpDisjunction

  -- ** Pretty printing
  , prettyEqStore
) where

import           GHC.Generics          (Generic)
import           Logic.Connectives
import           Term.Unification
import           Theory.Text.Pretty

import           Control.Monad.Fresh
import           Control.Monad.Bind
import           Control.Monad.Reader
import           Extension.Prelude

import           Debug.Trace.Ignore

import           Control.Basics
import           Control.DeepSeq
import           Control.Monad.State   hiding (get, modify, put)
import qualified Control.Monad.State   as MS

import           Data.Binary
import qualified Data.Foldable         as F
import           Data.List          (delete,find,intersect,intersperse,nub,(\\))
import           Data.Maybe
import qualified Data.Set              as S
import           Extension.Data.Label  hiding (for, get)
import qualified Extension.Data.Label  as L
-- import           Extension.Data.Monoid

------------------------------------------------------------------------------
-- Equation Store                                                --
------------------------------------------------------------------------------

-- | Index of disjunction in equation store
newtype SplitId = SplitId { unSplitId :: Integer }
  deriving( Eq, Ord, Show, Enum, Binary, NFData )

instance HasFrees SplitId where
    foldFrees    _   = const mempty
    foldFreesOcc _ _ = const mempty
    mapFrees     _   = pure

data StoreEntry = SubtermE (LNTerm, LNTerm)
                | SubstE LNSubstVFresh
  deriving( Eq, Ord, Generic, Show )

instance NFData StoreEntry
instance Binary StoreEntry

-- FIXME: Make comment parse.
--
-- The semantics of an equation store
-- > EqStore sigma_free
-- >         [ [sigma_i1,..,sigma_ik_i] | i <- [1..l] ]
-- where sigma_free = {t1/x1, .., tk/xk} is
-- >    (x1 = t1 /\ .. /\ xk = tk)
-- > /\_{i in [1..l]}
-- >    ([|sigma_i1|] \/ .. \/ [|sigma_ik_1|] \/ [|mtinfo_i|]
-- where @[|{t_1/x_1,..,t_l/x_l}|] = EX vars(t1,..,tl). x_1 = t1 /\ .. /\ x_l = t_l@.
-- Note that the 'LVar's in the range of a substitution are interpreted as
-- fresh variables, i.e., different by construction from the x_i which are
-- free variables.
--
-- The variables in the domain of the substitutions sigma_ij and all
-- variables in sigma_free are free (usually globally existentially quantified).
-- We use Conj [] as a normal form to denote True and Conj [Disj []]
-- as a normal form to denote False.
-- We say a variable @x@ is constrained by a disjunction if there is a substition
-- @s@ in the disjunction with @x `elem` dom s@.
data EqStore = EqStore {
      _eqsSubst       :: LNSubst
    , _eqsConj        :: Conj (SplitId, S.Set StoreEntry)
    , _eqsNextSplitId :: SplitId
    }
  deriving( Eq, Ord, Generic )

instance NFData EqStore
instance Binary EqStore

$(mkLabels [''EqStore])

-- | @emptyEqStore@ is the empty equation store.
emptyEqStore :: EqStore
emptyEqStore = EqStore emptySubst (Conj []) (SplitId 0)

-- | @True@ iff the 'EqStore' is contradictory.
eqsIsFalse :: EqStore -> Bool
eqsIsFalse = any ((S.empty == ) . snd) . getConj . L.get eqsConj

-- | The false conjunction. It is always identified with split number -1.
falseEqConstrConj :: Conj (SplitId, S.Set StoreEntry)
falseEqConstrConj = Conj [ (SplitId (-1), S.empty) ]

dropNameHintsBound :: EqStore -> EqStore
dropNameHintsBound = modify eqsConj (Conj . map (second (S.map dropNameHintsLNSubstVFresh)) . getConj)

dropNameHintsLNSubstVFresh :: StoreEntry -> StoreEntry
dropNameHintsLNSubstVFresh (SubtermE st) = SubtermE st
dropNameHintsLNSubstVFresh (SubstE subst) =
    SubstE $ substFromListVFresh $ zip (map fst slist)
                              ((`evalFresh` nothingUsed) . (`evalBindT` noBindings) $ renameDropNamehint (map snd slist))
  where slist = substToListVFresh subst
  
-- | @(from,to)@ is in @rawSubtermRel@ iff $(from,to)$ is in a singleton-disjunction in @eqsConj@
rawSubtermRel :: EqStore -> [(LNTerm,LNTerm)]
rawSubtermRel store = [ st | [SubtermE st] <- entryLists]
   where entryLists = [S.toList $ snd disj | disj <- getConj $ L.get eqsConj store]

-- Instances
------------

instance Apply SplitId where
    apply _ = id

instance Apply StoreEntry where
    apply subst (SubtermE (a,b)) = SubtermE (apply subst a, apply subst b)
    apply subst (SubstE s) = SubstE (composeVFresh s subst)

instance HasFrees StoreEntry where
    foldFrees f (SubtermE st) = foldFrees f st
    foldFrees f (SubstE subst) = foldFrees f subst
    foldFreesOcc _ _ = const mempty
    mapFrees f (SubtermE st) = SubtermE <$> mapFrees f st
    mapFrees f (SubstE subst) = SubstE <$> mapFrees f subst

instance HasFrees EqStore where
    foldFrees f (EqStore subst substs nextSplitId) =
        foldFrees f subst <> foldFrees f substs <> foldFrees f nextSplitId
    foldFreesOcc  _ _ = const mempty
    mapFrees f (EqStore subst substs nextSplitId) =
        EqStore <$> mapFrees f subst
                <*> mapFrees f substs
                <*> mapFrees f nextSplitId


instance Apply EqStore where
    apply subst (EqStore a b c) = EqStore (compose subst a) (fmap (fmap $ S.map $ apply subst) b) (apply subst c)


-- Equation Store
----------------------------------------------------------------------

-- | We use the empty set (disjunction) to denote false.
falseDisj :: S.Set StoreEntry
falseDisj = S.empty


-- Dealing with equations
----------------------------------------------------------------------

-- | Returns the list of all @SplitId@s valid for the given equation store
-- sorted by the size of the disjunctions.
splits :: EqStore -> [SplitId]
splits eqs = map fst $ nub $ sortOn snd
    [ (idx, S.size conj) | (idx, conj) <- getConj $ L.get eqsConj eqs ]
    
-- | Returns the list of @SplitId@s where the set of storeEntries is a singleton and @SubtermE@
-- This is used for finding new Split Goals that arise if these singletons are expanded 
onlySingleSubtermSplits :: EqStore -> [SplitId]
onlySingleSubtermSplits eqs = [ idx | (idx, [SubtermE _]) <- map (second S.toList) conjs]
  where
    conjs = getConj $ L.get eqsConj eqs

-- | Returns 'True' if the 'SplitId' is valid.
splitExists :: EqStore -> SplitId -> Bool
splitExists eqs = isJust . splitSize eqs

-- | Returns the number of cases for a given 'SplitId'.
splitSize :: EqStore -> SplitId -> Maybe Int
splitSize eqs sid =
    (S.size . snd) <$> (find ((sid ==) . fst) $ getConj $ L.get eqsConj $ eqs)

-- | Add a disjunction to the equation store at the beginning
addEntries :: EqStore -> (S.Set StoreEntry) -> (EqStore, SplitId)
addEntries eqStore disj =
    (   modify eqsConj ((Conj [(sid, disj)]) `mappend`)
      $ modify eqsNextSplitId succ
      $ eqStore
    , sid
    )
  where
    sid = L.get eqsNextSplitId eqStore

-- | Add a disjunction to the equation store at the beginning
addDisj :: EqStore -> (S.Set LNSubstVFresh) -> (EqStore, SplitId)
addDisj eqStore disj =
    (   modify eqsConj ((Conj [(sid, S.map SubstE disj)]) `mappend`)
      $ modify eqsNextSplitId succ
      $ eqStore
    , sid
    )
  where
    sid = L.get eqsNextSplitId eqStore

-- | @performSplit eqs i@ performs a case-split on the first disjunction
-- with the given 'SplitId'.
performSplit :: EqStore -> SplitId -> Maybe [EqStore]  --TODO-SUBTERM care for subterm predicates
performSplit eqStore idx =
    case break ((idx ==) . fst) (getConj $ L.get eqsConj eqStore) of
        (_, [])                   -> Nothing
        (before, (_, disj):after) -> Just $
            mkNewEqStore before after <$> S.toList disj
  where
    mkNewEqStore before after subst =
        fst $ addEntries (set eqsConj (Conj (before ++ after)) eqStore) (S.singleton subst)

addEqs :: MonadFresh m
       => MaudeHandle -> [Equal LNTerm] -> EqStore -> m (EqStore, Maybe SplitId, [SplitId])
addEqs hnd eqs0 eqStore =
    case unifyLNTermFactored eqs `runReader` hnd of
        (_, []) ->
            return (set eqsConj falseEqConstrConj eqStore, Nothing, [])
        (subst, [substFresh]) | substFresh == emptySubstVFresh -> do
            (newStore, ids) <- applyEqStore hnd subst eqStore
            return (newStore, Nothing, ids)
        (subst, substs) -> do
            (newStore, ids) <- applyEqStore hnd subst eqStore
            let (eqStore', sid) = addDisj newStore (S.fromList substs)
            return (eqStore', Just sid, ids)
            {-
            case splitStrat of
                SplitLater ->
                    return [ addDisj (applyEqStore hnd subst eqStore) (S.fromList substs) ]
                SplitNow ->
                    addEqsAC (modify eqsSubst (compose subst) eqStore)
                        <$> simpDisjunction hnd (const False) (Disj substs)
            -}
  where
    eqs = apply (L.get eqsSubst eqStore) $ trace (unlines ["addEqs: ", show eqs0]) $ eqs0
    {-
    addEqsAC eqSt (sfree, Nothing)   = [ applyEqStore hnd sfree eqSt ]
    addEqsAC eqSt (sfree, Just disj) =
      fromMaybe (error "addEqsSplit: impossible, splitAtPos failed")
                (splitAtPos (applyEqStore hnd sfree (addDisj eqSt (S.fromList disj))) 0)
-}

-- | Add a subterm predicate to the equation store.
--   Returns the split identifier of the disjunction in resulting equation store.
addSubterm :: MonadFresh m => MaudeHandle -> (LNTerm, LNTerm) -> EqStore -> m (EqStore, Maybe SplitId)
addSubterm hnd st eqStore = do
    entries <- recurseSubterms hnd (SubtermE st)
    let (finalStore, splitId) = addEntries eqStore (S.fromList entries)
    return (finalStore, Just splitId)

-- | apply CR-rules S_subterm-ac-recurse and S_subterm-recurse iteratively
recurseSubterms :: MonadFresh m => MaudeHandle -> StoreEntry -> m [StoreEntry] 
recurseSubterms hnd = recurse
  where
    recurse :: MonadFresh m => StoreEntry -> m [StoreEntry]
    recurse entry = do
      res <- step entry
      case res of
        Just entries -> liftM concat (mapM recurse entries)
        Nothing -> return [entry]

    -- outputs Nothing if the recursion is supposed to end (i.e. nothing changes)
    step :: MonadFresh m => StoreEntry -> m (Maybe [StoreEntry])
    step (SubtermE (small, big)) = case (viewTerm big) of
         Lit (Con _) -> return $ Just []  -- nothing can be a strict subterm of a constant
         Lit (Var v) -> if Var v `elem` small then return $ Just []  -- cannot be satisfied TODO-SUBTERM replace "elem" by "elem-and-not-below-cancellation"
                                              else return $ Nothing  -- do not recurse further; leave the subterm as is
         FApp (AC f) _ -> do  -- apply CR-rule subterm-ac-recurse  TODO-SUBTERM check whether we need to exclude cancellation operators like XOR (in this case, return Nothing)
           acSpecial <- acSubtermUnif f small big
           return $ Just $ (concatMap (eqOrSubterm small) (getFlattenedACTerms f big)) ++ acSpecial
         FApp (NoEq _) ts -> return $ Just $ concatMap (eqOrSubterm small) ts  -- apply CR-rule subterm-recurse
         FApp (C _) _ -> return Nothing  -- we treat commutative but not associative symbols as cancellation operators
         FApp List _ -> return Nothing  -- list seems to be unused
    step (SubstE _) = return Nothing

    -- returns all terms that are in the nested ac
    getFlattenedACTerms :: ACSym -> LNTerm -> [LNTerm]
    getFlattenedACTerms f term@(viewTerm -> FApp (AC sym) ts)
      = if sym == f then concatMap (getFlattenedACTerms f) ts else [term]
    getFlattenedACTerms _ term = [term]

    -- returns the unifiers of @small + newVar = big@
    acSubtermUnif :: MonadFresh m => ACSym -> LNTerm -> LNTerm -> m [StoreEntry]
    acSubtermUnif f small big = do
       let sort = sortOfLNTerm big  -- big has the sort of the ac operator
       var <- freshLVar "newVar" sort  -- generate a new variable
       let term = fAppAC f [small, varTerm var]  -- build the term small + newVar
       let unif = getUnifiers (Equal small term)  -- get unifiers of small + newVar = big
       let filterDomain = [x | x <- concatMap domVFresh unif, x /= var]  -- contains all vars used except for newVar
       return $ map (SubstE . restrictVFresh filterDomain) unif  -- filter out occurrences of newVar

    eqOrSubterm :: LNTerm -> LNTerm -> [StoreEntry]
    eqOrSubterm small t = SubtermE (small, t) : map SubstE (getUnifiers (Equal small t))  -- the unifiers for the equation

    getUnifiers :: Equal LNTerm -> [LNSubstVFresh]
    getUnifiers eq = unifyLNTerm [eq] `runReader` hnd

-- | Apply a substitution to an equation store and bring resulting equations into
--   normal form again by using unification. The application can "reactivate" subterm constraints.
--   If this happens, they are expanded again (by recurseSubterms) which might create new splitGoals.
--   These splitGoals are then returned in a list (along with the changed EqStore)
applyEqStore :: MonadFresh m => MaudeHandle -> LNSubst -> EqStore -> m (EqStore, [SplitId])
applyEqStore hnd asubst eqStore
    | dom asubst `intersect` varsRange asubst /= [] || trace (show ("applyEqStore", asubst, eqStore)) False
    = error $ "applyEqStore: dom and vrange not disjoint for `"++show asubst++"'"
    | otherwise
    = do 
      newConjs <- mapM modifyOneConj $ L.get eqsConj eqStore
      let newEqStore = EqStore newsubst newConjs $ L.get eqsNextSplitId eqStore
      let splitGoals = filter (\x -> notElem x $ onlySingleSubtermSplits eqStore) $ onlySingleSubtermSplits newEqStore
      return $ (newEqStore, splitGoals)  --TODO-SUBTERM: add right split ids (expanded singleton-subterms)
    -- FIXME maybe this is more performant with modify and second instead of making a new EqStore
    -- old code (without fresh monad):
    -- modify eqsConj (fmap (second (S.fromList . concatMap applyBound . S.toList))) $
    --          set eqsSubst newsubst eqStore
  where
    modifyOneConj :: MonadFresh m => (SplitId, S.Set StoreEntry) -> m (SplitId, S.Set StoreEntry)
    modifyOneConj (splitId, entries) = do
      newEntries <- fmap (S.fromList . concat) (mapM applyBound $ S.toList entries)
      return (splitId, newEntries)
    
    newsubst = asubst `compose` L.get eqsSubst eqStore
    
    applyBound :: MonadFresh m => StoreEntry -> m [StoreEntry]
    applyBound (SubtermE (small, big)) = recurseSubterms hnd $ SubtermE (apply newsubst small, apply newsubst big)
    applyBound (SubstE s) = return $ map (SubstE . restrictVFresh (varsRange newsubst ++ domVFresh s)) $
        (`runReader` hnd) $ unifyLNTerm
          [ Equal (apply newsubst (varTerm lv)) t
          | let slist = substToListVFresh s,
            -- variables in the range are fresh, so we have to rename
            -- them away from all other variables in unification problem
            -- NOTE: these variables never enter the global context
            let ran = renameAvoiding (map snd slist)
                                     (domVFresh s ++ varsRange newsubst),
            (lv,t) <- zip (map fst slist) ran
          ]

{- NOTES for @applyEqStore tau@ to a fresh substitution sigma:
[ FIXME: extend explanation to multiple unifiers ]
Let dom(sigma) = x1,..,xk, vrange(sigma) = y1, .. yl, vrange(tau) = z1,..,zn
Fresh substitution denotes formula
  exists #y1, .., #yl. x1 = t1 /\ .. /\ xk = tk
for variables #yi that do not clash with xi and zi [renameAwayFrom]
and with vars(ti) `subsetOf` [#y1, .. #yl].
We apply tau with vrange(tau) = z1,..,zn to the formula to obtain
  exists ##y1, .., ##yl. tau(x1) = t1 /\ .. /\ tau(xk) = tk
unification then yields a lemma
  forall xi zi #yi.
    tau(x1) = t1 /\ .. /\ tau(xk) = tk
    <-> exists vars(s1,..sm). x1 = .. /\ z1 = .. /\ #y1 = ..
So we have
  exists #y1, .., #yl.
    exists vars(s1,..sm). x1 = .. /\ z1 = .. /\ #y1 = ..
<=>
  exists vars(s1,..sm). x1 = .. /\ z1 = ..
      /\  (exists #y1, .., #yl. #y1 = ..)
<=> [restric]
  exists vars(s1,..sm). x1 = .. /\ z1 = .. /\ True
-}

-- | Add the given rule variants.
addRuleVariants :: Disj LNSubstVFresh -> EqStore -> (EqStore, SplitId)
addRuleVariants (Disj substs) eqStore
    | dom freeSubst `intersect` concatMap domVFresh substs /= []
    = error $ "addRuleVariants: Nonempty intersection between domain of variants and free substitution. "
              ++"This case has not been implemented, add rule variants earlier."
    | otherwise = addDisj eqStore (S.fromList substs)
  where
    freeSubst = L.get eqsSubst eqStore


{-
-- | Return the set of variables that is constrained by disjunction at give position.
constrainedVarsPos :: EqStore -> Int -> [LVar]
constrainedVarsPos eqStore k
    | k < length conj = frees (conj!!k)
    | otherwise       = []
  where
    conj = getConj . L.get eqsConj $ eqStore
-}

-- Simplifying disjunctions
----------------------------------------------------------------------

-- | Simplify given disjunction via EqStore simplification. Obtains fresh
--   names for variables from the underlying 'MonadFresh'.
simpDisjunction :: MonadFresh m
                => MaudeHandle
                -> (LNSubst -> LNSubstVFresh -> Bool)
                -> Disj LNSubstVFresh
                -> m (LNSubst, Maybe [LNSubstVFresh])
simpDisjunction hnd isContr disj0 = do
    (eqStore', _) <- simp hnd isContr eqStore  -- there cannot be a new split goal in simp if there are no subterms
    return (L.get eqsSubst eqStore', wrap $ L.get eqsConj eqStore')
  where
    eqStore = fst $ addDisj emptyEqStore (S.fromList $ getDisj $ disj0)
    wrap (Conj [])          = Nothing
    wrap (Conj [(_, disj)]) = Just $ [x | SubstE x <- S.toList disj]
    wrap conj               =
        error ("simplifyDisjunction: imposible, unexpected conjunction `"
               ++ show conj ++ "'")


-- Simplification
----------------------------------------------------------------------

-- | @simp eqStore@ simplifies the equation store.
simp :: MonadFresh m => MaudeHandle -> (LNSubst -> LNSubstVFresh -> Bool) -> EqStore -> m (EqStore, [SplitId])
simp hnd isContr eqStore = liftM swap $ runStateT (loopSimp1 []) 
               (trace (show ("eqStore", eqStore)) (eqStore))
  where
    loopSimp1 oldSplits = do
      newMaysplits <- simp1 hnd isContr
      case newMaysplits of
        Nothing -> return $ oldSplits
        Just newSplits -> loopSimp1 $ oldSplits ++ newSplits   
        


-- | @simp1@ tries to execute one simplification step
--   for the equation store. It returns @Nothing@ if
--   the equation store was not modified.
--   If it returns @Just list@ it was modified and new split goals arose at the split id's in the list 
simp1 :: MonadFresh m => MaudeHandle -> (LNSubst -> LNSubstVFresh -> Bool) -> StateT EqStore m (Maybe [SplitId])
simp1 hnd isContr = do
    eqs <- MS.get
    if eqsIsFalse eqs
        then return Nothing
        else do
          b1 <- simpMinimize (isContr (L.get eqsSubst eqs))
          b2 <- simpRemoveRenamings
          b3 <- simpEmptyDisj
          let ids3 = if or [b1, b2, b3] then Just [] else Nothing
          ids4 <- acc ids3 $ foreachDisj hnd simpSingleton
          ids5 <- acc ids4 $ foreachDisj hnd simpAbstractSortedVar
          ids6 <- acc ids5 $ foreachDisj hnd simpIdentify
          ids7 <- acc ids6 $ foreachDisj hnd simpAbstractFun
          ids8 <- acc ids7 $ foreachDisj hnd simpAbstractName
          (trace (show ("simp:", [b1, b2, b3]))) $
              return $ ids8
        where
          acc :: MonadFresh m => Maybe [SplitId] -> m (Maybe [SplitId]) -> m (Maybe [SplitId])
          acc oldsplit mMaysplit = do
            maysplit <- mMaysplit
            case oldsplit of
              Nothing -> return maysplit
              Just split -> return $ maybe oldsplit (\newsplit -> Just $ split ++ newsplit) maysplit


-- | Remove variable renamings in fresh substitutions.
simpRemoveRenamings :: MonadFresh m => StateT EqStore m Bool
simpRemoveRenamings = do
    Conj conj <- gets (L.get eqsConj)
    list <- return [y | x <- conj, SubstE y <- S.toList $ snd x]
    if F.any (\subst -> domVFresh subst /= domVFresh (removeRenamings subst)) list
      then modM eqsConj (fmap (second $ S.map remove)) >> return True
      else return False
    where
      remove (SubstE x) = SubstE (removeRenamings x)
      remove (SubtermE x) = SubtermE x


-- | If empty disjunction is found, the whole conjunct
--   can be simplified to False.
simpEmptyDisj :: MonadFresh m => StateT EqStore m Bool
simpEmptyDisj = do
    conj <- getM eqsConj
    if (F.any ((== falseDisj) . snd) conj && conj /= falseEqConstrConj)
      then eqsConj =: falseEqConstrConj >> return True
      else return False


-- | If there is a singleton disjunction, it can be
--   composed with the free substitution.
simpSingleton :: MonadFresh m
              => [LNSubstVFresh]
              -> m (Maybe (Maybe LNSubst, [S.Set LNSubstVFresh]))
simpSingleton [subst0] = do
        subst <- freshToFree subst0
        return (Just (Just subst, []))
simpSingleton _        = return Nothing


-- | If all substitutions @si@ map a variable @v@ to terms with the same
--   outermost function symbol @f@, then they all contain the common factor
--   @{v |-> f(x1,..,xk)}@ for fresh variables xi and we can replace
--   @x |-> ..@ by @{x1 |-> ti1, x2 |-> ti2, ..}@ in all substitutions @si@.
simpAbstractFun :: MonadFresh m
                => [LNSubstVFresh]
                -> m (Maybe (Maybe LNSubst, [S.Set LNSubstVFresh]))
simpAbstractFun []             = return Nothing
simpAbstractFun (subst:others) = case commonOperators of
    [] -> return Nothing
    -- abstract all arguments
    (v, o, argss@(args:_)):_ | all ((==length args) . length) argss -> do
        fvars <- mapM (\_ -> freshLVar "x" LSortMsg) args
        let substs' = zipWith (abstractAll v fvars) (subst:others) argss
            fsubst  = substFromList [(v, fApp o (map varTerm fvars))]
        return $ Just (Just fsubst, [S.fromList substs'])
    -- abstract first two arguments
    (v, o@(AC _), argss):_ -> do
        fv1 <- freshLVar "x" LSortMsg
        fv2 <- freshLVar "x" LSortMsg
        let substs' = zipWith (abstractTwo o v fv1 fv2) (subst:others) argss
            fsubst  = substFromList [(v, fApp o (map varTerm [fv1,fv2]))]
        return $ Just (Just fsubst, [S.fromList substs'])
    (_, _ ,_):_ ->
        error "simpAbstract: impossible, invalid arities or List operator encountered."
  where
    commonOperators = do
        (v, viewTerm -> FApp o args) <- substToListVFresh subst
        let images = map (\s -> imageOfVFresh s v) others
            argss  = [ args' | Just (viewTerm -> FApp o' args') <- images, o' == o ]
        guard (length argss == length others)
        return (v, o, args:argss)

    abstractAll v freshVars s args = substFromListVFresh $
        filter ((/= v) . fst) (substToListVFresh s) ++ zip freshVars args

    abstractTwo o v fv1 fv2 s args = substFromListVFresh $
        filter ((/= v) . fst) (substToListVFresh s) ++ newMappings args
      where
        newMappings []      =
            error "simpAbstract: impossible, AC symbols must have arity >= 2."
        newMappings [a1,a2] = [(fv1, a1), (fv2, a2)]
        -- here we always abstract from left to right and do not
        -- take advantage of the AC property of o
        newMappings (a:as)  = [(fv1, a),  (fv2, fApp o as)]


-- | If all substitutions @si@ map a variable @v@ to the same name @n@,
--   then they all contain the common factor
--   @{v |-> n}@ and we can remove @{v -> n}@ from all substitutions @si@
simpAbstractName :: MonadFresh m
                 => [LNSubstVFresh]
                 -> m (Maybe (Maybe LNSubst, [S.Set LNSubstVFresh]))
simpAbstractName []             = return Nothing
simpAbstractName (subst:others) = case commonNames of
    []           -> return Nothing
    (v, c):_     ->
        return $ Just (Just $ substFromList [(v, c)]
                      , [S.fromList (map (\s -> restrictVFresh (delete v (domVFresh s)) s) (subst:others))])
  where
    commonNames = do
        (v, c@(viewTerm -> Lit (Con _))) <- substToListVFresh subst
        let images = map (\s -> imageOfVFresh s v) others
        guard (length images == length [ () | Just c' <- images, c' == c])
        return (v, c)


-- | If all substitutions @si@ map a variable @v@ to variables @xi@ of the same
--   sort @s@ then they all contain the common factor
--   @{v |-> y}@ for a fresh variable of sort @s@
--   and we can replace @{v -> xi}@ by @{y -> xi}@ in all substitutions @si@
simpAbstractSortedVar :: MonadFresh m
                      => [LNSubstVFresh]
                      -> m (Maybe (Maybe LNSubst, [S.Set LNSubstVFresh]))
simpAbstractSortedVar []             = return Nothing
simpAbstractSortedVar (subst:others) = case commonSortedVar of
    []            -> return Nothing
    (v, s, lvs):_ -> do
        fv <- freshLVar (lvarName v) s
        return $ Just (Just $ substFromList [(v, varTerm fv)]
                      , [S.fromList (zipWith (replaceMapping v fv) lvs (subst:others))])
  where
    commonSortedVar = do
        (v, (viewTerm -> Lit (Var lx))) <- substToListVFresh subst
        guard (sortCompare (lvarSort v)  (lvarSort lx) == Just GT)
        let images = map (\s -> imageOfVFresh s v) others
            -- FIXME: could be generalized to choose topsort s of all images if s < sortOf v
            --        could also be generalized to terms of a given sort
            goodImages = [ ly | Just (viewTerm -> Lit (Var ly)) <- images, lvarSort lx == lvarSort ly]
        guard (length images == length goodImages)
        return (v, lvarSort lx, (lx:goodImages))
    replaceMapping v fv lv sigma =
        substFromListVFresh $ (filter ((/=v) . fst) $ substToListVFresh sigma) ++ [(fv, varTerm lv)]

-- | If all substitutions @si@ map two variables @x@ and @y@ to identical terms @ti@,
--   then they all contain the common factor @{x |-> y}@ for a fresh variable @z@
--   and we can remove @{x |-> ti}@ from all @si@.
simpIdentify :: MonadFresh m
             => [LNSubstVFresh]
             -> m (Maybe (Maybe LNSubst, [S.Set LNSubstVFresh]))
simpIdentify []             = return Nothing
simpIdentify (subst:others) = case equalImgPairs of
    []         -> return Nothing
    ((v,v'):_) -> do
        let (vkeep, vremove) = case sortCompare (lvarSort v) (lvarSort v') of
                                 Just GT -> (v', v)
                                 Just _  -> (v, v')
                                 Nothing -> error $ "EquationStore.simpIdentify: impossible, variables with incomparable sorts: "
                                                    ++ show v ++" and "++ show v'
        return $ Just (Just  (substFromList [(vremove, varTerm vkeep)]),
                       [S.fromList (map (removeMappings [vkeep]) (subst:others))])
  where
    equalImgPairs = do
        (v,t)    <- substToListVFresh subst
        (v', t') <- substToListVFresh subst
        guard (t == t' && v < v' && all (agrees_on v v') others)
        return (v,v')
    agrees_on v v' s =
        imageOfVFresh s v == imageOfVFresh s v' && isJust (imageOfVFresh s v)
    removeMappings vs s = restrictVFresh (domVFresh s \\ vs) s


-- | Simplify by removing substitutions that occur twice in a disjunct.
--   We could generalize this function by using AC-equality or subsumption.
--   Comment by Philip: that description is not really correct.
--   It rather filters out substitutions with @isContr (= substCreatesNonNormalTerms)@
simpMinimize :: MonadFresh m => (LNSubstVFresh -> Bool) -> StateT EqStore m Bool
simpMinimize isContr = do
    Conj conj <- gets (L.get eqsConj)
    list <- return [y | x <- conj, SubstE y <- S.toList $ snd x]
    --conj <- MS.gets (L.get eqsConj)
    if F.any check list
      then MS.modify (set eqsConj (fmap (second minimize) $ Conj conj)) >> return True
      else return False
  where
    minimize :: S.Set StoreEntry -> S.Set StoreEntry
    minimize substs
      | SubstE emptySubstVFresh `S.member` substs = S.singleton (SubstE emptySubstVFresh)
      | otherwise                                 = S.filter (not . myContr) substs
    myContr (SubstE x) = isContr x
    myContr (SubtermE _) = False
    check subst = subst == emptySubstVFresh || isContr subst


-- | Traverse disjunctions and execute @f@ until it returns
--   @Just (mfreeSubst, disjs)@.
--   Then the @disjs@ is inserted at the current position, if @mfreeSubst@ is
--   @Just freesubst@, then it is applied to the equation store.
--   @Nothing@ is returned if no modification took place
--   If @Just splits@ is returned, new split goals have to be inserted at @splits@ (possibly empty)
foreachDisj :: forall m. MonadFresh m
            => MaudeHandle
            -> ([LNSubstVFresh] -> m (Maybe (Maybe LNSubst, [S.Set LNSubstVFresh])))
            -> StateT EqStore m (Maybe [SplitId])
foreachDisj hnd f =
    go [] =<< gets (getConj . L.get eqsConj)
  where
    go :: [(SplitId, S.Set StoreEntry)] -> [(SplitId, S.Set StoreEntry)] -> StateT EqStore m (Maybe [SplitId])
    go _     []               = return Nothing
    go lefts ((idx,d):rights) = do
        b <- lift $ f ([y | SubstE y <- S.toList d])
        case b of
          Nothing              -> go ((idx,d):lefts) rights
          Just (msubst, disjs) -> do
              eqsConj =: Conj (reverse lefts ++ ((,) idx <$> map (S.map SubstE) disjs) ++ rights)
              splitIds <- case msubst of
                Nothing -> return []
                Just s  -> do
                   oldStore <- MS.get
                   (newStore, ids) <- applyEqStore hnd s oldStore
                   MS.put newStore
                   return ids
              -- FIXME maybe this is more performant with with modify instead of get -> put
              -- old code (without fresh monad):
              -- maybe (return ()) (\s -> MS.modify (applyEqStore hnd s)) msubst
              return $ Just splitIds

------------------------------------------------------------------------------
-- Pretty printing
------------------------------------------------------------------------------

-- | Pretty print an 'EqStore'.
prettyEqStore :: HighlightDocument d => EqStore -> d
prettyEqStore eqs@(EqStore substFree (Conj disjs) _nextSplitId) = vcat $
  [if eqsIsFalse eqs then text "CONTRADICTORY" else emptyDoc] ++
  map combine
    [ ("subst", vcat $ prettySubst (text . show) (text . show) substFree)
    , ("conj",  vcat $ map ppDisj disjs)
    ]
  where
    combine (header, d) = fsep [keyword_ header <> colon, nest 2 d]
    ppDisj (idx, substs) =
        text (show (unSplitId idx) ++ ".") <-> numbered' conjs
      where
        conjs  = map ppEntry $ S.toList substs

    ppEq (a,b) =
      prettyNTerm (lit (Var a)) $$ nest (6::Int) (opEqual <-> prettyNTerm b)

    ppEntry (SubstE subst) = sep
      [ hsep (opExists : map prettyLVar (varsRangeVFresh subst)) <> opDot
      , nest 2 $ fsep $ intersperse opLAnd $ map ppEq $ substToListVFresh subst
      ]
    ppEntry (SubtermE (a,b)) = prettyNTerm a $$ nest (6::Int) (opSubterm <-> prettyNTerm b)


-- Derived and delayed instances
--------------------------------

instance Show EqStore where
    show = render . prettyEqStore
