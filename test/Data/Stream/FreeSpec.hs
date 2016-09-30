{-# LANGUAGE ScopedTypeVariables #-}
module Data.Stream.FreeSpec
    (spec)
where

import Data.Stream.Free
import Test.Hspec

spec :: Spec
spec =
    do describe "Smoke test" $
           do it "should work" $
                  do v1 <-
                         runSink $
                         listSource [1..10000]
                            `connect` mapStream (+1)
                            `connect` filterStream (>5000) `connect` listSink
                     v1 `shouldBe` ([5001..10001] :: [Int])
