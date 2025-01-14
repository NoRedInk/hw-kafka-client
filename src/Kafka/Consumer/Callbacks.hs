{-# LANGUAGE BangPatterns #-}

module Kafka.Consumer.Callbacks
  ( rebalanceCallback,
    offsetCommitCallback,
    module X,
  )
where

import Control.Arrow ((&&&))
import Control.Monad (forM_, void)
import qualified Data.Text as Text
import qualified Debug.Trace
import Foreign.ForeignPtr (newForeignPtr_)
import Foreign.Ptr (nullPtr)
import Kafka.Callbacks as X
import Kafka.Consumer.AssignmentStrategy
import Kafka.Consumer.Convert (fromNativeTopicPartitionList', fromNativeTopicPartitionList'')
import Kafka.Consumer.Types (KafkaConsumer (..), RebalanceEvent (..), TopicPartition (..))
import Kafka.Internal.RdKafka
import Kafka.Internal.Setup (Callback (..), HasKafka (..), HasKafkaConf (..), Kafka (..), KafkaConf (..), getRdMsgQueue)
import Kafka.Types (BatchSize (BatchSize), KafkaError (..), PartitionId (..), TopicName (..))

-- | Sets a callback that is called when rebalance is needed.
rebalanceCallback :: (KafkaConsumer -> RebalanceEvent -> IO ()) -> Callback
rebalanceCallback callback =
  RebalanceCallback $ \kc@(KafkaConf con _ _) consumerAssignmentStrategies -> rdKafkaConfSetRebalanceCb con (realCb kc consumerAssignmentStrategies)
  where
    realCb kc cas k err pl = do
      k' <- newForeignPtr_ k
      pls <- newForeignPtr_ pl
      setRebalanceCallback callback cas (KafkaConsumer (Kafka k') kc) (KafkaResponseError err) pls

-- | Sets a callback that is called when rebalance is needed.
--
-- The results of automatic or manual offset commits will be scheduled
-- for this callback and is served by 'Kafka.Consumer.pollMessage'.
--
-- If no partitions had valid offsets to commit this callback will be called
-- with 'KafkaResponseError' 'RdKafkaRespErrNoOffset' which is not to be considered
-- an error.
offsetCommitCallback :: (KafkaConsumer -> KafkaError -> [TopicPartition] -> IO ()) -> Callback
offsetCommitCallback callback =
  Callback $ \kc@(KafkaConf conf _ _) -> rdKafkaConfSetOffsetCommitCb conf (realCb kc)
  where
    realCb kc k err pl = do
      k' <- newForeignPtr_ k
      pls <- fromNativeTopicPartitionList' pl
      callback (KafkaConsumer (Kafka k') kc) (KafkaResponseError err) pls

-------------------------------------------------------------------------------
redirectPartitionQueue :: Kafka -> TopicName -> PartitionId -> RdKafkaQueueTPtr -> IO ()
redirectPartitionQueue (Kafka k) (TopicName t) (PartitionId p) q = do
  mpq <- rdKafkaQueueGetPartition k (Text.unpack t) p
  case mpq of
    Nothing -> return ()
    Just pq -> rdKafkaQueueForward pq q

setRebalanceCallback ::
  (KafkaConsumer -> RebalanceEvent -> IO ()) ->
  [ConsumerAssignmentStrategy] ->
  KafkaConsumer ->
  KafkaError ->
  RdKafkaTopicPartitionListTPtr ->
  IO ()
setRebalanceCallback f assignmentStrategies k e pls = do
  ps <- fromNativeTopicPartitionList'' pls
  let assignment = (tpTopicName &&& tpPartition) <$> ps
  let (Kafka kptr) = getKafka k

  case assignmentStrategies of
    CooperativeStickyAssignor : _ ->
      case e of
        KafkaResponseError RdKafkaRespErrAssignPartitions -> do
          f k (RebalanceBeforeAssign assignment)
          void $ rdKafkaIncrementalAssign kptr pls

          mbq <- getRdMsgQueue $ getKafkaConf k
          case mbq of
            Nothing -> pure ()
            Just mq -> do
              void $ rdKafkaPausePartitions kptr pls
              forM_ ps (\tp -> redirectPartitionQueue (getKafka k) (tpTopicName tp) (tpPartition tp) mq)
              void $ rdKafkaResumePartitions kptr pls

          f k (RebalanceAssign assignment)
        KafkaResponseError RdKafkaRespErrRevokePartitions -> do
          f k (RebalanceBeforeRevoke assignment)

          void $ rdKafkaIncrementalUnassign kptr pls

          f k (RebalanceRevoke assignment)
        x -> error $ "Rebalance: UNKNOWN response: " <> show x
    _ ->
      case e of
        KafkaResponseError RdKafkaRespErrAssignPartitions -> do
          f k (RebalanceBeforeAssign assignment)
          void $ rdKafkaAssign kptr pls

          mbq <- getRdMsgQueue $ getKafkaConf k
          case mbq of
            Nothing -> pure ()
            Just mq -> do
              {- Magnus Edenhill:
                  If you redirect after assign() it means some messages may be forwarded to the single consumer queue,
                  so either do it before assign() or do: assign(); pause(); redirect; resume()
              -}
              void $ rdKafkaPausePartitions kptr pls
              forM_ ps (\tp -> redirectPartitionQueue (getKafka k) (tpTopicName tp) (tpPartition tp) mq)
              void $ rdKafkaResumePartitions kptr pls

          f k (RebalanceAssign assignment)
        KafkaResponseError RdKafkaRespErrRevokePartitions -> do
          f k (RebalanceBeforeRevoke assignment)
          void $ newForeignPtr_ nullPtr >>= rdKafkaAssign kptr
          f k (RebalanceRevoke assignment)
        x -> error $ "Rebalance: UNKNOWN response: " <> show x
