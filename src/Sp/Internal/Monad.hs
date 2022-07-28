module Sp.Internal.Monad
  ( Eff
  , Effect
  , Handling
  , Handler
  , unsafeIO
  , lift
  , interpret
  , reinterpret
  , interpose
  , reinterpose
  , send
  , toEff
  , control
  , abort
  , runEff
  , (:>)
  , IOE
  , runIOE
  ) where

import           Control.Monad          (ap, liftM, (>=>))
import           Control.Monad.IO.Class (MonadIO (liftIO))
import           Data.Kind              (Type)
import           Sp.Internal.Ctl        (Ctl, Marker, prompt, raise, runCtl, yield)
import           Sp.Internal.Env        (Rec, (:>))
import qualified Sp.Internal.Env        as Rec
import           System.IO.Unsafe       (unsafeDupablePerformIO)

type Effect = (Type -> Type) -> Type -> Type

type Env es = Rec InternalHandler es

data Result es a = Result
  { resEnv :: !(Env es)
  , resVal :: !a
  }

newtype Eff es a = Eff { unEff :: Env es -> Ctl (Result es a) }

newtype InternalHandler e = InternalHandler { runHandler :: forall es a. e :> es => e (Eff es) a -> Eff es a }

instance Functor (Eff es) where
  fmap = liftM

instance Applicative (Eff es) where
  pure x = Eff \es -> pure (Result es x)
  (<*>) = ap

instance Monad (Eff es) where
  Eff m >>= f = Eff (m >=> \(Result es' x) -> unEff (f x) es')

data Handling esSend es r = Handling
  {-# UNPACK #-} !(Env esSend)
  {-# UNPACK #-} !(Marker r)

type Handler e es r = forall esSend a. e :> esSend => Handling esSend es r -> e (Eff esSend) a -> Eff es a

-- This "unsafe" IO function is perfectly safe in the sense that it won't cause crashes or other undefined
-- behaviors itself; it is only unsafe in the sense that you can embed arbitrary IO actions in any effect environment
-- therefore breaking effect abstraction.
unsafeIO :: IO a -> Eff es a
unsafeIO m = Eff (\es -> Result es <$> liftIO m)
{-# INLINE unsafeIO #-}

toInternalHandler :: Marker r -> Env es -> Handler e es r -> InternalHandler e
toInternalHandler mark es hdl = InternalHandler \e -> Eff \esSend ->
  Result esSend <$> (resVal <$> unEff (hdl (Handling esSend mark) e) es)
{-# INLINE toInternalHandler #-}

alter :: (Env es' -> Env es) -> Eff es a -> Eff es' a
alter f (Eff m) = Eff \es -> Result es <$> (resVal <$> m (f es))
{-# INLINE alter #-}

handle :: Handler e es' a -> (InternalHandler e -> Env es' -> Env es) -> Eff es a -> Eff es' a
handle hdl f (Eff m) = Eff \es -> Result es <$> prompt \mark -> resVal <$> m (f (toInternalHandler mark es hdl) es)
{-# INLINE handle #-}

interpret :: Handler e es a -> Eff (e : es) a -> Eff es a
interpret hdl = handle hdl Rec.cons
{-# INLINE interpret #-}

reinterpret :: Handler e (e' : es) a -> Eff (e : es) a -> Eff (e' : es) a
reinterpret hdl = handle hdl \ih es -> Rec.cons ih $ Rec.tail es
{-# INLINE reinterpret #-}

interpose :: e :> es => Handler e es a -> Eff es a -> Eff es a
interpose hdl = handle hdl Rec.update
{-# INLINE interpose #-}

reinterpose :: e :> es => Handler e (e' : es) a -> Eff es a -> Eff (e' : es) a
reinterpose hdl = handle hdl \ih es -> Rec.update ih $ Rec.tail es
{-# INLINE reinterpose #-}

lift :: Eff es a -> Eff (e : es) a
lift = alter Rec.tail
{-# INLINE lift #-}

send :: e :> es => e (Eff es) a -> Eff es a
send e = Eff \es -> unEff (runHandler (Rec.index es) e) es
{-# INLINE send #-}

toEff :: Handling esSend es r -> Eff esSend a -> Eff es a
toEff (Handling esSend _) = alter (const esSend)
{-# INLINE toEff #-}

control :: Handling esSend es r -> ((a -> Eff es r) -> Eff es r) -> Eff es a
control (Handling _ mark) f = Eff \es -> yield mark \cont ->
  resVal <$> unEff (f \x -> Eff \es' -> Result es <$> cont (Result es' x)) es
{-# INLINE control #-}

abort :: Handling esSend es r -> r -> Eff es a
abort (Handling _ mark) x = Eff (const $ raise mark x)
{-# INLINE abort #-}

runEff :: Eff '[] a -> a
runEff (Eff m) = resVal $ unsafeDupablePerformIO (runCtl $ m Rec.empty)
{-# INLINE runEff #-}

data IOE :: Effect

instance IOE :> es => MonadIO (Eff es) where
  liftIO = unsafeIO

runIOE :: Eff '[IOE] a -> IO a
runIOE m = runCtl $ resVal <$> unEff (interpret (const $ \case) m) Rec.empty
{-# INLINE runIOE #-}
