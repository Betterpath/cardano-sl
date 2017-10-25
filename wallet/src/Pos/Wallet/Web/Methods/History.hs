{-# LANGUAGE TypeFamilies #-}

-- | Wallet history

module Pos.Wallet.Web.Methods.History
       ( MonadWalletHistory
       , getHistoryLimited
       , addHistoryTxMeta
       , constructCTx
       , getCurChainDifficulty
       , updateTransaction
       ) where

import           Universum

import           Control.Exception            (throw)
import qualified Data.Map.Strict              as Map
import qualified Data.Set                     as S
import           Data.Time.Clock.POSIX        (POSIXTime, getPOSIXTime)
import           Formatting                   (build, sformat, stext, (%))
import           Serokell.Util                (listJson)
import           System.Wlog                  (WithLogger, logWarning)

import           Pos.Client.Txp.History       (MonadTxHistory, TxHistoryEntry (..),
                                               txHistoryListToMap)
import           Pos.Core                     (ChainDifficulty, timestampToPosix)
import           Pos.Txp.Core.Types           (TxId)
import           Pos.Util.LogSafe             (logInfoS)
import           Pos.Util.Servant             (encodeCType)
import           Pos.Wallet.WalletMode        (MonadBlockchainInfo (..), getLocalHistory)
import           Pos.Wallet.Web.ClientTypes   (AccountId (..), Addr, CId, CTx (..), CTxId,
                                               CTxMeta (..), CWAddressMeta (..),
                                               ScrollLimit, ScrollOffset, Wal, mkCTx)
import           Pos.Wallet.Web.Error         (WalletError (..))
import           Pos.Wallet.Web.Methods.Logic (MonadWalletLogicRead)
import           Pos.Wallet.Web.Pending       (PendingTx (..), ptxPoolInfo)
import           Pos.Wallet.Web.State         (AddressLookupMode (Ever), MonadWalletDB,
                                               MonadWalletDBRead, addOnlyNewTxMetas,
                                               getHistoryCache, getPendingTx, getTxMeta,
                                               getWalletAccountIds, getWalletPendingTxs,
                                               setWalletTxMeta)
import           Pos.Wallet.Web.Util          (decodeCTypeOrFail, getAccountAddrsOrThrow,
                                               getWalletAddrs, getWalletAddrsSet)


type MonadWalletHistory ctx m =
    ( MonadWalletLogicRead ctx m
    , MonadBlockchainInfo m
    , MonadTxHistory m
    )

getFullWalletHistory
    :: MonadWalletHistory ctx m
    => CId Wal -> m (Map TxId (CTx, POSIXTime), Word)
getFullWalletHistory cWalId = do
    addrs <- mapM decodeCTypeOrFail =<< getWalletAddrs Ever cWalId

    unfilteredLocalHistory <- getLocalHistory addrs

    blockHistory <- getHistoryCache cWalId >>= \case
        Just hist -> pure hist
        Nothing -> do
            logWarning $
                sformat ("getFullWalletHistory: history cache is empty for wallet #"%build)
                cWalId
            pure mempty

    let localHistory = unfilteredLocalHistory `Map.difference` blockHistory

    logTxHistory "Block" blockHistory
    logTxHistory "Mempool" localHistory

    fullHistory <- addRecentPtxHistory cWalId $ localHistory `Map.union` blockHistory
    walAddrs    <- getWalletAddrsSet Ever cWalId
    diff        <- getCurChainDifficulty
    cHistory <- forM fullHistory (constructCTx cWalId walAddrs diff)
    pure (cHistory, fromIntegral $ Map.size cHistory)

getHistory
    :: MonadWalletHistory ctx m
    => CId Wal
    -> [AccountId]
    -> Maybe (CId Addr)
    -> m (Map TxId (CTx, POSIXTime), Word)
getHistory cWalId accIds mAddrId = do
    -- FIXME: searching when only AddrId is provided is not supported yet.
    accAddrs <- S.fromList . map cwamId <$> concatMapM (getAccountAddrsOrThrow Ever) accIds
    allAccIds <- getWalletAccountIds cWalId

    let filterFn :: Map TxId (CTx, POSIXTime) -> Map TxId (CTx, POSIXTime)
        !filterFn = case mAddrId of
          Nothing
            | S.fromList accIds == S.fromList allAccIds
              -- can avoid doing any expensive filtering in this case
                        -> identity
            | otherwise -> filterByAddrs accAddrs

          Just addr
            | addr `S.member` accAddrs -> filterByAddrs (S.singleton addr)
            | otherwise                -> throw errorBadAddress

    first filterFn <$> getFullWalletHistory cWalId
  where
    filterByAddrs :: S.Set (CId Addr)
                  -> Map TxId (CTx, POSIXTime)
                  -> Map TxId (CTx, POSIXTime)
    filterByAddrs addrs = Map.filter (fits addrs . fst)

    fits :: S.Set (CId Addr) -> CTx -> Bool
    fits addrs CTx{..} =
        let inpsNOuts = map fst (ctInputs ++ ctOutputs)
        in  any (`S.member` addrs) inpsNOuts
    errorBadAddress = RequestError $
        "Specified wallet/account does not contain specified address"

getHistoryLimited
    :: MonadWalletHistory ctx m
    => Maybe (CId Wal)
    -> Maybe AccountId
    -> Maybe (CId Addr)
    -> Maybe ScrollOffset
    -> Maybe ScrollLimit
    -> m ([CTx], Word)
getHistoryLimited mCWalId mAccId mAddrId mSkip mLimit = do
    (cWalId, accIds) <- case (mCWalId, mAccId) of
        (Nothing, Nothing)      -> throwM errorSpecifySomething
        (Just _, Just _)        -> throwM errorDontSpecifyBoth
        (Just cWalId', Nothing) -> do
            accIds' <- getWalletAccountIds cWalId'
            pure (cWalId', accIds')
        (Nothing, Just accId)   -> pure (aiWId accId, [accId])
    (unsortedThs, n) <- getHistory cWalId accIds mAddrId
    let sortedTxh = sortByTime (Map.elems unsortedThs)
    pure (applySkipLimit sortedTxh, n)
  where
    sortByTime :: [(CTx, POSIXTime)] -> [CTx]
    sortByTime thsWTime =
        -- TODO: if we use a (lazy) heap sort here, we can get the
        -- first n values of the m sorted elements in O(m + n log m)
        map fst $ sortWith (Down . snd) thsWTime
    applySkipLimit = take limit . drop skip
    limit = (fromIntegral $ fromMaybe defaultLimit mLimit)
    skip = (fromIntegral $ fromMaybe defaultSkip mSkip)
    defaultLimit = 100
    defaultSkip = 0
    errorSpecifySomething = RequestError $
        "Please specify either walletId or accountId"
    errorDontSpecifyBoth = RequestError $
        "Please do not specify both walletId and accountId at the same time"

addHistoryTxMeta
    :: MonadWalletDB ctx m
    => CId Wal
    -> TxHistoryEntry
    -> m ()
addHistoryTxMeta cWalId = addHistoryTxsMeta cWalId . txHistoryListToMap . one

-- This functions is helper to do @addHistoryTx@ for
-- all txs from mempool as one Acidic transaction.
addHistoryTxsMeta
    :: MonadWalletDB ctx m
    => CId Wal
    -> Map TxId TxHistoryEntry
    -> m ()
addHistoryTxsMeta cWalId historyEntries = do
    metas <- mapM toMeta historyEntries
    addOnlyNewTxMetas cWalId metas
  where
    toMeta THEntry {..} = CTxMeta <$> case _thTimestamp of
        Nothing -> liftIO getPOSIXTime
        Just ts -> pure $ timestampToPosix ts

constructCTx
    :: (MonadThrow m, MonadWalletDBRead ctx m)
    => CId Wal
    -> Set (CId Addr)
    -> ChainDifficulty
    -> TxHistoryEntry
    -> m (CTx, POSIXTime)
constructCTx cWalId walAddrsSet diff wtx@THEntry{..} = do
    let cId = encodeCType _thTxId
    meta <- maybe (CTxMeta <$> liftIO getPOSIXTime) -- It's impossible case but just in case
            pure =<< getTxMeta cWalId cId
    ptxCond <- encodeCType . fmap _ptxCond <$> getPendingTx cWalId _thTxId
    either (throwM . InternalError) (pure . (, ctmDate meta)) $
        mkCTx diff wtx meta ptxCond walAddrsSet

getCurChainDifficulty :: MonadBlockchainInfo m => m ChainDifficulty
getCurChainDifficulty = maybe localChainDifficulty pure =<< networkChainDifficulty

updateTransaction :: MonadWalletDB ctx m => AccountId -> CTxId -> CTxMeta -> m ()
updateTransaction accId txId txMeta = do
    setWalletTxMeta (aiWId accId) txId txMeta

addRecentPtxHistory
    :: (WithLogger m, MonadWalletDBRead ctx m)
    => CId Wal -> Map TxId TxHistoryEntry -> m (Map TxId TxHistoryEntry)
addRecentPtxHistory wid currentHistory = do
    pendingTxs <- getWalletPendingTxs wid
    let candidates = toCandidates pendingTxs
    logTxHistory "Pending" candidates
    return $ Map.union currentHistory candidates
  where
    toCandidates =
            txHistoryListToMap
        .   mapMaybe (ptxPoolInfo . _ptxCond)
        .   fromMaybe []

logTxHistory
    :: (Container t, Element t ~ TxHistoryEntry, WithLogger m, MonadIO m)
    => Text -> t -> m ()
logTxHistory desc =
    logInfoS .
    sformat (stext%" transactions history: "%listJson) desc .
    map _thTxId . toList
