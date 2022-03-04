{-# LANGUAGE OverloadedStrings #-}

module Kafka.Consumer.AssignmentStrategy where

import           Data.Text            (Text)
import qualified Data.Text            as Text

-- | Assignment strategy. Currently supported: RangeAssignor and CooperativeStickyAssignor
-- Default to RangeAssignor
data ConsumerAssignmentStrategy =
  RangeAssignor
  | CooperativeStickyAssignor

instance Show ConsumerAssignmentStrategy where
  show RangeAssignor = "range"
  show CooperativeStickyAssignor = "cooperative-sticky"

assignmentStrategy :: [ConsumerAssignmentStrategy] -> Text
assignmentStrategy [] = "range,roundrobin"
assignmentStrategy [a] = Text.pack (show a)
assignmentStrategy (a:as) = Text.pack (show a) <> "," <> assignmentStrategy as

