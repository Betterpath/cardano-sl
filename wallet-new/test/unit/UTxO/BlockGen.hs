{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TemplateHaskell            #-}

module UTxO.BlockGen
    ( genValidBlockchain
    ) where

import           Universum hiding (use)

import           Control.Lens hiding (elements)
import           Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Map as Map
import qualified Data.Set as Set
import           Pos.Util.Chrono (OldestFirst (..))
import           Test.QuickCheck

import           UTxO.Context
import           UTxO.DSL
import           UTxO.PreChain

-- | Blockchain Generator Monad
--
-- When generating transactions, we need to keep track of addresses,
-- balances, and transaction IDs so that we can create valid future
-- transactions without wasting time searching and validating.
newtype BlockGen h a
    = BlockGen
    { unBlockGen :: StateT (BlockGenCtx h) Gen a
    } deriving (Functor, Applicative, Monad, MonadState (BlockGenCtx h))

-- | The context and settings for generating arbitrary blockchains.
data BlockGenCtx h
    = BlockGenCtx
    { _bgcCurrentUtxo            :: !(Utxo h Addr)
    -- ^ The mapping of current addresses and their current account values.
    , _bgcFreshHash              :: !Int
    -- ^ A fresh hash value for each new transaction.
    , _bgcCurrentBlockchain      :: !(Ledger h Addr)
    -- ^ The accumulated blockchain thus far.
    , _bgcInputPartiesUpperLimit :: !Int
    -- ^ The upper limit on the number of parties that may be selected as
    -- inputs to a transaction
    }

makeLenses ''BlockGenCtx

genValidBlockchain :: Hash h Addr => PreChain h Gen
genValidBlockchain = toPreChain newChain

toPreChain
    :: Hash h Addr
    => BlockGen h [[Value -> Transaction h Addr]]
    -> PreChain h Gen
toPreChain = toPreChainWith identity

toPreChainWith
    :: Hash h Addr
    => (BlockGenCtx h -> BlockGenCtx h)
    -> BlockGen h [[Value -> Transaction h Addr]]
    -> PreChain h Gen
toPreChainWith settings bg = PreChain $ \boot -> do
    ks <- runBlockGenWith settings boot bg
    return
        $ OldestFirst
        . fmap OldestFirst
        . zipFees ks

-- | Given an initial bootstrap 'Transaction' and a function to customize
-- the other settings in the 'BlockGenCtx', this function will initialize
-- the generator and run the action provided.
runBlockGenWith
    :: Hash h Addr
    => (BlockGenCtx h -> BlockGenCtx h)
    -> Transaction h Addr
    -> BlockGen h a
    -> Gen a
runBlockGenWith settings boot m =
    evalStateT (unBlockGen m) (settings (initializeCtx boot))

-- | Create an initial context from the boot transaction.
initializeCtx :: Hash h Addr => Transaction h Addr -> BlockGenCtx h
initializeCtx boot@Transaction{..} = BlockGenCtx {..}
  where
    _bgcCurrentUtxo = ledgerUtxo _bgcCurrentBlockchain
    _bgcFreshHash = 1
    _bgcCurrentBlockchain = ledgerSingleton boot
    _bgcInputPartiesUpperLimit = 1

-- | Lift a 'Gen' action into the 'BlockGen' monad.
liftGen :: Gen a -> BlockGen h a
liftGen = BlockGen . lift

-- | Provide a fresh hash value for a transaction.
freshHash :: BlockGen h Int
freshHash = do
    i <- use bgcFreshHash
    bgcFreshHash += 1
    pure i

-- | Returns true if the 'addrActorIx' is the 'IxAvvm' constructor.
isAvvmAddr :: Addr -> Bool
isAvvmAddr addr =
    case addrActorIx addr of
        IxAvvm _ -> True
        _        -> False

bgcNonAvvmUtxo :: Getter (BlockGenCtx h) (Utxo h Addr)
bgcNonAvvmUtxo =
    bgcCurrentUtxo . to (utxoRestrictToAddr (not . isAvvmAddr))

selectSomeInputs :: Hash h Addr => BlockGen h (NonEmpty (Input h Addr, Output Addr))
selectSomeInputs = do
    utxoMap <- uses bgcNonAvvmUtxo utxoToMap
    upperLimit <- use bgcInputPartiesUpperLimit
    input1 <- liftGen $ elements (Map.toList utxoMap)
    -- it seems likely that we'll want to weight the frequency of
    -- just-one-input more heavily than lots-of-inputs
    n <- liftGen . frequency $ zip
            [upperLimit, upperLimit-1 .. 0]
            (map pure [0 .. upperLimit])
    otherInputs <- loop (Map.delete (fst input1) utxoMap) n
    pure (input1 :| otherInputs)
  where
    loop utxo n
        | n <= 0 = pure []
        | otherwise = do
            inp <- liftGen $ elements (Map.toList utxo)
            rest <- loop (Map.delete (fst inp) utxo) (n - 1)
            pure (inp : rest)

selectDestinations :: Hash h Addr => Set (Input h Addr) -> BlockGen h (NonEmpty Addr)
selectDestinations notThese = do
    utxo <- uses bgcNonAvvmUtxo (utxoRemoveInputs notThese)
    addr1 <- liftGen $ elements (map (outAddr . snd) (utxoToList utxo))
    pure (addr1 :| [])

-- | Create a fresh transaction that depends on the fee provided to it.
newTransaction :: Hash h Addr => BlockGen h (Value -> Transaction h Addr)
newTransaction = do
    inputs'outputs <- selectSomeInputs
    destinations <- selectDestinations (foldMap Set.singleton (map fst inputs'outputs))
    hash' <- freshHash

    let txn fee =
            let (inputs, outputs) = divvyUp inputs'outputs destinations fee
             in Transaction
                { trFresh = 0
                , trFee = fee
                , trHash = hash'
                , trIns = inputs
                , trOuts = outputs
                }

    -- we assume that the fee is 0 for initializing these transactions
    bgcCurrentBlockchain %= ledgerAdd (txn 0)
    ledger <- use bgcCurrentBlockchain
    bgcCurrentUtxo .= ledgerUtxo ledger
    pure txn

divvyUp
    :: Hash h Addr
    => NonEmpty (Input h Addr, Output Addr)
    -> NonEmpty Addr
    -> Value
    -> (Set (Input h Addr), [Output Addr])
divvyUp inputs'outputs destinations fee = (inputs, outputs)
  where
    inputs = foldMap (Set.singleton . fst) inputs'outputs
    destLen = fromIntegral (length destinations)
    -- if we don't know what the fee is yet (eg a 0), then we want to use
    -- the max fee for safety's sake
    totalValue = sum (map (outVal . snd) inputs'outputs)
        `safeSubtract` if fee == 0 then maxFee else fee
    valPerOutput = totalValue `div` destLen
    outputs = toList (map (\addr -> Output addr valPerOutput) destinations)

-- | 'Value' is an alias for 'Word64', which underflows. This detects
-- underflow and returns @0@ for underflowing values.
safeSubtract :: Value -> Value -> Value
safeSubtract x y
    | z > x     = 0
    | otherwise = z
  where
    z = x - y

maxFee :: Num a => a
maxFee = 180000

newBlock :: Hash h Addr => BlockGen h [Value -> Transaction h Addr]
newBlock = do
    txnCount <- liftGen $ choose (1, 10)
    replicateM txnCount newTransaction

newChain :: Hash h Addr => BlockGen h [[Value -> Transaction h Addr]]
newChain = do
    blockCount <- liftGen $ choose (1, 10)
    replicateM blockCount newBlock

zipFees
    :: [[Value -> Transaction h Addr]]
    -> ([[Value]] -> [[Transaction h Addr]])
zipFees = zipWith (zipWith ($))
