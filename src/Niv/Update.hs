{-# LANGUAGE Arrows #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}

module Niv.Update where

import Control.Applicative
import Control.Arrow
import Data.Aeson (FromJSON, ToJSON, Value)
import Data.String
import UnliftIO
import qualified Control.Category as Cat
import qualified Data.Aeson as Aeson
import qualified Data.HashMap.Strict as HMS
import qualified Data.Text as T

type JSON a = (ToJSON a, FromJSON a)

data UpdateFailed
  = FailNoSuchKey T.Text
  | FailBadIo SomeException
  | FailZero
  | FailCheck
  | FailTemplate T.Text [T.Text]
  deriving Show

data UpdateRes a b
  = UpdateReady (UpdateReady b)
  | UpdateNeedMore (a -> IO (UpdateReady b))
  deriving Functor

data UpdateReady b
  = UpdateSuccess BoxedAttrs b
  | UpdateFailed UpdateFailed
  deriving Functor

execUpdate :: Attrs -> Update () a -> IO a
execUpdate attrs a = snd <$> runUpdate attrs a

evalUpdate :: Attrs -> Update () a -> IO Attrs
evalUpdate attrs a = fst <$> runUpdate attrs a

runUpdate :: Attrs -> Update () a -> IO (Attrs, a)
runUpdate (boxAttrs -> attrs) a = runUpdate' attrs a >>= feed
  where
    feed = \case
      UpdateReady res -> hndl res
      UpdateNeedMore next -> next (()) >>= hndl
    hndl = \case
      UpdateSuccess f v -> (,v) <$> unboxAttrs f
      UpdateFailed e -> error $ "baaaah: " <> show e

runBox :: Box a -> IO a
runBox = boxOp

instance ArrowZero Update where
    zeroArrow = Zero

instance ArrowPlus Update where
    (<+>) = Plus

instance Arrow Update where
    arr = Arr
    first = First

data Update b c where
  Id :: Update a a
  Compose :: (Compose b c) -> Update b c
  Arr :: (b -> c) -> Update b c
  First :: Update b c -> Update (b, d) (c, d)
  Zero :: Update b c
  Plus :: Update b c -> Update b c -> Update b c
  Check :: (a -> Bool) -> Update (Box a) ()
  Load :: T.Text -> Update () (Box Value)
  UseOrSet :: T.Text -> Update (Box Value) (Box Value)
  Update :: T.Text -> Update (Box Value) (Box Value)
  Run :: (a -> IO b)  -> Update (Box a) (Box b)
  Template :: Update (Box T.Text) (Box T.Text)

instance Cat.Category Update where
    id = Id
    f . g = Compose (Compose' f g)

data Compose a c = forall b. Compose' (Update b c) (Update a b)

data Box a = Box
  { boxNew :: Bool
  , boxOp :: IO a
  }
  deriving Functor

instance Applicative Box where
  pure x = Box { boxNew = False, boxOp = pure x }
  f <*> v = Box
    { boxNew = (||) (boxNew f) (boxNew v)
    , boxOp = boxOp f <*> boxOp v
    }

instance Semigroup a => Semigroup (Box a) where
  (<>) = liftA2 (<>)

instance IsString (Box T.Text) where
  fromString str = Box { boxNew = False, boxOp = pure $ T.pack str }

instance Show (Update b c) where
  show = \case
    Id -> "Id"
    Compose (Compose' f g)-> "(" <> show f <> " . " <> show g <> ")"
    Arr _f -> "Arr"
    First a -> "First " <> show a
    Zero -> "Zero"
    Plus l r -> "(" <> show l <> " + " <> show r <> ")"
    Check _ch -> "Check"
    Load k -> "Load " <> T.unpack k
    UseOrSet k -> "UseOrSet " <> T.unpack k
    Update k -> "Update " <> T.unpack k
    Run _act -> "Io"
    Template -> "Template"

type BoxedAttrs = HMS.HashMap T.Text (Freedom, Box Value)
type Attrs = HMS.HashMap T.Text (Freedom, Value)

unboxAttrs :: BoxedAttrs -> IO Attrs
unboxAttrs = traverse (\(fr, v) -> (fr,) <$> runBox v)

boxAttrs :: Attrs -> BoxedAttrs
boxAttrs = fmap (\(fr, v) -> (fr,
    case fr of
      -- TODO: explain why hacky
      Locked -> (pure v) { boxNew = True } -- XXX: somewhat hacky
      Free -> pure v
    ))

data Freedom
  = Locked
  | Free
  deriving (Eq, Show)

-- TODO: tryAny all IOs
runUpdate' :: BoxedAttrs -> Update a b -> IO (UpdateRes a b)
runUpdate' attrs = \case
    Id -> pure $ UpdateNeedMore $ pure . UpdateSuccess attrs
    Arr f -> pure $ UpdateNeedMore $ pure . UpdateSuccess attrs . f
    Zero -> pure $ UpdateReady (UpdateFailed FailZero)
    Plus l r -> runUpdate' attrs l >>= \case
      UpdateReady (UpdateFailed{}) -> runUpdate' attrs r
      UpdateReady (UpdateSuccess f v) -> pure $ UpdateReady (UpdateSuccess f v)
      UpdateNeedMore next -> pure $ UpdateNeedMore $ \v -> next v >>= \case
        UpdateSuccess f res -> pure $ UpdateSuccess f res
        UpdateFailed {} -> runUpdate' attrs r >>= \case
          UpdateReady res -> pure res
          UpdateNeedMore next' -> next' v
    Load k -> pure $ UpdateReady $ do
      case HMS.lookup k attrs of
        Just (_, v') -> UpdateSuccess attrs v'
        Nothing -> UpdateFailed $ FailNoSuchKey k
    First a -> do
      runUpdate' attrs a >>= \case
        UpdateReady (UpdateFailed e) -> pure $ UpdateReady $ UpdateFailed e
        UpdateReady (UpdateSuccess fo ba) -> pure $ UpdateNeedMore $ \gtt -> do
          pure $ UpdateSuccess fo (ba, snd gtt)
        UpdateNeedMore next -> pure $ UpdateNeedMore $ \gtt -> do
          next (fst gtt) >>= \case
            UpdateFailed e -> pure $ UpdateFailed e
            UpdateSuccess f res -> do
              pure $ UpdateSuccess f (res, snd gtt)
    Run act -> pure (UpdateNeedMore $ \gtt -> do
      pure $ UpdateSuccess attrs $ Box (boxNew gtt) (act =<< runBox gtt))
    Check ch -> pure (UpdateNeedMore $ \gtt -> do
      v <- runBox gtt
      if ch v
      then pure $ UpdateSuccess attrs ()
      else pure $ UpdateFailed FailCheck)
    UseOrSet k -> pure $ case HMS.lookup k attrs of
      Just (Locked, v) -> UpdateReady $ UpdateSuccess attrs v
      Just (Free, v) -> UpdateReady $ UpdateSuccess attrs v
      Nothing -> UpdateNeedMore $ \gtt -> do
        let attrs' = HMS.singleton k (Locked, gtt) <> attrs
        pure $ UpdateSuccess attrs' gtt
    Update k -> pure $ case HMS.lookup k attrs of
      Just (Locked, v) -> UpdateReady $ UpdateSuccess attrs v
      Just (Free, v) -> UpdateNeedMore $ \gtt -> do
        if (boxNew gtt)
        then pure $ UpdateSuccess (HMS.insert k (Locked, gtt) attrs) gtt
        else pure $ UpdateSuccess attrs v
      Nothing -> UpdateNeedMore $ \gtt -> do
        pure $ UpdateSuccess (HMS.insert k (Locked, gtt) attrs) gtt
    Compose (Compose' f g) -> runUpdate' attrs g >>= \case
      UpdateReady (UpdateFailed e) -> pure $ UpdateReady $ UpdateFailed e
      UpdateReady (UpdateSuccess attrs' act) -> runUpdate' attrs' f >>= \case
        UpdateReady (UpdateFailed e) -> pure $ UpdateReady $ UpdateFailed e
        UpdateReady (UpdateSuccess attrs'' act') -> pure $ UpdateReady $ UpdateSuccess attrs'' act'
        UpdateNeedMore next -> UpdateReady <$> next act
      UpdateNeedMore next -> pure $ UpdateNeedMore $ \gtt -> do
        next gtt >>= \case
          UpdateFailed e -> pure $ UpdateFailed e
          UpdateSuccess attrs' act -> runUpdate' attrs' f >>= \case
            UpdateReady ready -> pure ready
            UpdateNeedMore next' -> next' act
    Template -> pure $ UpdateNeedMore $ \v -> do
      v' <- runBox v
      case renderTemplate (\k -> (decodeBox . snd) <$> HMS.lookup k attrs) v' of
        Nothing -> pure $ UpdateFailed $ FailTemplate v' (HMS.keys attrs)
        Just v'' -> pure $ UpdateSuccess attrs (v'' <* v) -- carries over v's newness

decodeBox :: FromJSON a => Box Value -> Box a
decodeBox v = v { boxOp = boxOp v >>= decodeValue }

decodeValue :: FromJSON a => Value -> IO a
decodeValue v = case Aeson.fromJSON v of
  Aeson.Success x -> pure x
  Aeson.Error str -> error $ "Could not decode: " <> show v <> " :" <> str

-- | Renders the template. Returns 'Nothing' if some of the attributes are
-- missing.
--  TODO: fix doc
--  renderTemplate [("foo", "bar")] "<foo>" == pure (Just "bar")
--  renderTemplate [("foo", "bar")] "<baz>" == pure Nothing
renderTemplate :: (T.Text -> Maybe (Box T.Text)) -> T.Text -> Maybe (Box T.Text)
renderTemplate vals = \case
    (T.uncons -> Just ('<', str)) -> do
      case T.span (/= '>') str of
        (key, T.uncons -> Just ('>', rest)) -> do
          let v = vals key
          (liftA2 (<>) v) (renderTemplate vals rest)
        _ -> Nothing
    (T.uncons -> Just (c, str)) -> fmap (T.cons c) <$> renderTemplate vals str
    (T.uncons -> Nothing) -> Just $ pure T.empty
    -- XXX: isn't this redundant?
    _ -> Just $ pure T.empty


template :: Update (Box T.Text) (Box T.Text)
template = Template

check :: (a -> Bool) -> Update (Box a) ()
check = Check

load :: FromJSON a => T.Text -> Update () (Box a)
load k = Load k >>> arr decodeBox

-- TODO: should input really be Box?
useOrSet :: JSON a => T.Text -> Update (Box a) (Box a)
useOrSet k =
    arr (fmap Aeson.toJSON) >>>
    UseOrSet k >>>
    arr decodeBox

update :: JSON a => T.Text -> Update (Box a) (Box a)
update k =
    arr (fmap Aeson.toJSON) >>>
    Update k >>>
    arr decodeBox

run :: (a -> IO b) -> Update (Box a) (Box b)
run = Run

-- | Like 'run' but forces evaluation
run' :: (a -> IO b) -> Update (Box a) (Box b)
run' act = Run act >>> dirty

dirty :: Update (Box a) (Box a)
dirty = arr (\v -> v { boxNew = True })
