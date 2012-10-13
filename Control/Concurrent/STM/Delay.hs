{-# LANGUAGE CPP #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE Rank2Types #-}
-- |
-- Module:      Control.Concurrent.STM.Delay
-- Copyright:   (c) Joseph Adams 2012
-- License:     BSD3
-- Maintainer:  joeyadams3.14159@gmail.com
-- Portability: Requires GHC 7+
--
-- One-shot timer whose duration can be updated
--
-- Suppose you are managing a network connection, and want to time it out if no
-- messages are received in over five minutes.  You can do something like this:
--
-- >import Control.Concurrent.Async (race_) -- from the async package
-- >import Control.Concurrent.STM
-- >import Control.Concurrent.STM.Delay
-- >import Control.Exception
-- >import Control.Monad
-- >
-- >manageConnection :: Connection -> IO Message -> (Message -> IO a) -> IO ()
-- >manageConnection conn toSend onRecv =
-- >    bracket (newDelay five_minutes) cancelDelay $ \delay ->
-- >    foldr1 race_
-- >        [ do atomically $ waitDelay delay
-- >             fail "Connection timed out"
-- >        , forever $ toSend >>= send conn
-- >        , forever $ do
-- >            msg <- recv conn
-- >            updateDelay delay five_minutes
-- >            onRecv msg
-- >        ]
-- >  where
-- >    five_minutes = 5 * 60 * 1000000
module Control.Concurrent.STM.Delay (
    -- * Managing delays
    Delay,
    newDelay,
    updateDelay,
    cancelDelay,

    -- * Waiting for expiration
    waitDelay,
    tryWaitDelay,
) where

import Control.Applicative      ((<$>))
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception        (mask_)
import Control.Monad            (join)

#if MIN_VERSION_base(4,4,0)
import qualified GHC.Event as Ev
#endif

-- | A 'Delay' is an updatable timer that rings only once.
data Delay = forall k.
             Delay !(TVar Bool)
                   !(DelayImpl k)
                   !k

instance Eq Delay where
    (==) (Delay a _ _) (Delay b _ _) = a == b

type TimeoutCallback = IO ()

data DelayImpl k = DelayImpl
    { delayStart  :: Int -> TimeoutCallback -> IO k
    , delayUpdate :: TimeoutCallback -> k -> Int -> IO ()
    , delayStop   :: k -> IO ()
    }

-- | Create a new 'Delay' that will ring in the given number of microseconds.
newDelay :: Int -> IO Delay
newDelay t = getDelayImpl (\impl -> newDelayWith impl t)

newDelayWith :: DelayImpl k -> Int -> IO Delay
newDelayWith impl t = do
    var <- newTVarIO False
    k   <- delayStart impl t $ atomically $ writeTVar var True
    return (Delay var impl k)

-- | Set an existing 'Delay' to ring in the given number of microseconds
-- (after 'updateDelay' is called), rather than when it was going to ring.
-- If the 'Delay' has already rung, do nothing.
updateDelay :: Delay -> Int -> IO ()
updateDelay (Delay var impl k) t =
    delayUpdate impl (atomically $ writeTVar var True) k t

-- | Set a 'Delay' so it will never ring.  If the 'Delay' has already rung,
-- do nothing.
cancelDelay :: Delay -> IO ()
cancelDelay (Delay _var impl k) =
    delayStop impl k

-- | Block until the 'Delay' rings.  If the 'Delay' has already rung,
-- return immediately.
waitDelay :: Delay -> STM ()
waitDelay delay = do
    expired <- tryWaitDelay delay
    if expired then return ()
               else retry

-- | Non-blocking version of 'waitDelay'.
-- Return 'True' if the 'Delay' has rung.
tryWaitDelay :: Delay -> STM Bool
tryWaitDelay (Delay v _ _) = readTVar v

------------------------------------------------------------------------
-- Drivers

getDelayImpl :: (forall k. DelayImpl k -> IO r) -> IO r
#if MIN_VERSION_base(4,4,0)
getDelayImpl cont = do
    m <- Ev.getSystemEventManager
    case m of
        Nothing  -> cont implThread
        Just mgr -> cont (implEvent mgr)
#else
getDelayImpl cont = cont implThread
#endif

#if MIN_VERSION_base(4,4,0)
-- | Use the timeout API in "GHC.Event"
implEvent :: Ev.EventManager -> DelayImpl Ev.TimeoutKey
implEvent mgr = DelayImpl
    { delayStart  = Ev.registerTimeout mgr
    , delayUpdate = \_ -> Ev.updateTimeout mgr
    , delayStop   = Ev.unregisterTimeout mgr
    }
#endif

-- | Use threads and threadDelay:
--
--  [delayStart] Fork a thread to wait the given length of time,
--               then set the TVar.
--
--  [delayUpdate] Stop the existing thread and fork a new thread.
--
--  [delayStop] Stop the existing thread.
implThread :: DelayImpl (MVar (Maybe TimeoutThread))
implThread = DelayImpl
    { delayStart  = \t io -> forkTimeoutThread t io >>= newMVar . Just
    , delayUpdate = \io mv t -> replaceThread (Just <$> forkTimeoutThread t io) mv
    , delayStop   = replaceThread (return Nothing)
    }
  where
    replaceThread new mv =
        join $ mask_ $ do
            m <- takeMVar mv
            case m of
                Nothing -> do
                    new >>= putMVar mv
                    return (return ())
                Just tt -> do
                    m' <- stopTimeoutThread tt
                    new >>= putMVar mv
                    return $ case m' of
                        Nothing   -> return ()
                        Just kill -> kill

------------------------------------------------------------------------
-- TimeoutThread

data TimeoutThread = TimeoutThread !ThreadId !(MVar ())

-- instance Eq TimeoutThread where
--     (==) (TimeoutThread a _) (TimeoutThread b _) = a == b
-- instance Ord TimeoutThread where
--     compare (TimeoutThread a _) (TimeoutThread b _) = compare a b

-- | Fork a thread to perform an action after the given number of
-- microseconds.
--
-- 'forkTimeoutThread' is non-interruptible.
forkTimeoutThread :: Int -> IO () -> IO TimeoutThread
forkTimeoutThread t io = do
    mv <- newMVar ()
    tid <- compat_forkIOUnmasked $ do
        threadDelay t
        m <- tryTakeMVar mv
        -- If m is Just, this thread will not be interrupted,
        -- so no need for a 'mask' between the tryTakeMVar and the action.
        case m of
            Nothing -> return ()
            Just _  -> io
    return (TimeoutThread tid mv)

-- | Prevent the 'TimeoutThread' from performing its action.  If it's too late,
-- return 'Nothing'.  Otherwise, return an action (namely, 'killThread') for
-- cleaning up the underlying thread.
--
-- 'stopTimeoutThread' has a nice property: it is /non-interruptible/.
-- This means that, in an exception 'mask', it will not poll for exceptions.
-- See "Control.Exception" for more info.
--
-- However, the action returned by 'stopTimeoutThread' /does/ poll for
-- exceptions.  That's why 'stopTimeoutThread' returns this action rather than
-- simply doing it.  This lets the caller do it outside of a critical section.
stopTimeoutThread :: TimeoutThread -> IO (Maybe (IO ()))
stopTimeoutThread (TimeoutThread tid mv) =
    maybe Nothing (\_ -> Just (killThread tid)) <$> tryTakeMVar mv

------------------------------------------------------------------------
-- Compatibility

compat_forkIOUnmasked :: IO () -> IO ThreadId
#if MIN_VERSION_base(4,4,0)
compat_forkIOUnmasked io = forkIOWithUnmask (\_ -> io)
#else
compat_forkIOUnmasked = forkIOUnmasked
#endif
