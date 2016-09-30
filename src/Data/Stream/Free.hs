{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE BangPatterns #-}
module Data.Stream.Free
    ( StreamT, Source, Stream, Sink
    , yield, await
    , connect, runSink
    , listSource
    , mapStream, filterStream
    , listSink
    )
where

import Data.Void
import Control.Monad
import Control.Monad.Trans
import Control.Monad.Trans.Free.Church

data StreamF i o r f
    = Yield o f
    | Await (Maybe i -> f)
    | Done r

instance Functor (StreamF i o r) where
    fmap f x =
        case x of
          Yield t a -> Yield t (f a)
          Await g -> Await (f . g)
          Done r -> Done r

-- | A stream of input values @i@, producting output values  @o@, running actions in  @m@ monad,
-- and producing a final value @r@
newtype StreamT i o r m a =
    StreamT { _unStreamT :: FT (StreamF i o r) m a }
    deriving (Monad, Functor, Applicative, MonadIO, MonadTrans)

-- | Stream of output values without any input consumption
type Source m o = StreamT () o () m ()

-- | Consume a stream of input values and produce a new stream of output values
type Stream i m o = StreamT i o () m ()

-- | Consume a stream of input values and produce final result
type Sink i m a = StreamT i Void a m a

done :: r -> StreamT i o r m r
done r = StreamT $ liftF (Done r)

-- | Send a value downstream
yield :: forall m i o r. o -> StreamT i o r m ()
yield x = StreamT $ liftF (Yield x ())

-- | Pull a value from upstream
await :: forall m i o r. StreamT i o r m (Maybe i)
await = StreamT $ liftF (Await id)

data StStatus i o r m
    = StDone r
    | StAwaits (Maybe i -> m (StStatus i o r m))
    | StYielded o (m (StStatus i o r m))

toCont :: Monad m => StreamT i o r m r -> m (StStatus i o r m)
toCont (StreamT str) =
    runFT str (pure . StDone) $ \pack action ->
    case action of
      Done x -> pure (StDone x)
      Await f -> pure $ StAwaits $ \val -> pack (f val)
      Yield x f -> pure $ StYielded x (pack f)

-- | Connect two streams
--
-- > listSource [1, 2, 3] `connect` mapStream (+1)  `connect` filterStream (>2) `connect` listSink
--
connect :: MonadIO m => Stream i m o -> StreamT o p r m r -> StreamT i p r m r
connect left right =
    do lCont <- lift $ toCont left
       rCont <- lift $ toCont right
       let loop l r =
               case (l, r) of
                 (_, StDone x) -> done x
                 (StAwaits x, StAwaits _) ->
                     do val <- await
                        l' <- lift (x val)
                        loop l' r
                 (StAwaits x, StYielded y g) ->
                     do yield y
                        val <- await
                        l' <- lift (x val)
                        r' <- lift g
                        loop l' r'
                 (StYielded x f, StAwaits g) ->
                     do r' <- lift (g (Just x))
                        l' <- lift f
                        loop l' r'
                 (StYielded _ _, StYielded y g) ->
                     do yield y
                        r' <- lift g
                        loop l r'
                 (StDone _, StAwaits g) ->
                     do r' <- lift (g Nothing)
                        loop l r'
                 (StDone _, StYielded y g) ->
                     do yield y
                        r' <- lift g
                        loop l r'
       loop lCont rCont

-- | Retrieve the final value from a @Sink@
runSink :: Monad m => Sink a m b -> m b
runSink (StreamT s) =
    flip iterT s $ \action ->
    case action of
      Done q -> pure q
      Await g -> g Nothing
      Yield _ g -> g

-- | Turn a list into a source
listSource :: [a] -> Source m a
listSource = mapM_ yield

-- | Map over all values in the stream
mapStream :: (i -> o) -> Stream i m o
mapStream f =
    let loop =
            do val <- await
               case val of
                 Nothing -> pure ()
                 Just t -> yield (f t) >> loop
    in loop

-- | Filter values in stream
filterStream :: (i -> Bool) -> Stream i m i
filterStream f =
    let loop =
            do val <- await
               case val of
                 Nothing -> pure ()
                 Just t ->
                     do when (f t) $ yield t
                        loop
    in loop

-- | Turn a stream into a list, consuming all outputs
listSink :: Sink a m [a]
listSink =
    do let loop !accum =
               do val <- await
                  case val of
                    Nothing -> pure (reverse accum)
                    Just t -> loop (t : accum)
       loop []
