{-# LANGUAGE CPP #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE Rank2Types #-}
-- |
-- Module:      System.Timer
-- Copyright:   (c) Joseph Adams 2012
-- License:     BSD3
-- Maintainer:  joeyadams3.14159@gmail.com
-- Portability: Requires GHC 7+
--
-- This uses event manager timeouts when the threaded RTS is available
-- (see "GHC.Event").  Otherwise, it falls back to forked threads and
-- 'threadDelay'.
module Control.Concurrent.STM.Timer (
    -- * Managing timers
    Timer,
    newTimer,
    newTimer_,
    setTimer,
    clearTimer,

    -- * Waiting for expiration
    waitTimer,
    tryWaitTimer,
) where

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception

import qualified GHC.Event as Ev

-- | A 'Timer' can be in one of three states:
--
--  [Cleared] @waitTimer@ will 'retry' indefinitely.
--
--  [Pending] @waitTimer@ will 'retry' until a given length of time has passed.
--
--  [Expired] @waitTimer@ will return immediately.
data Timer = forall k. Timer !(TVar (TVar Bool))
                             !(TimerImpl k)
                             !(MVar (Maybe k))
    -- We use nested TVars so we can reset the timer atomically, without
    -- worrying about listeners seeing an expiration before the reset process
    -- is complete.

instance Eq Timer where
    (==) (Timer a _ _) (Timer b _ _) = a == b

data TimerImpl k = TimerImpl
    { timerStart :: Int -> IO () -> IO k
    , timerStop  :: k -> IO ()
    }

implThreadId :: TimerImpl ThreadId
implThreadId = TimerImpl
    { timerStart = \t signal -> compat_forkIOUnmasked (threadDelay t >> signal)
    , timerStop  = killThread
    }

implEvent :: Ev.EventManager -> TimerImpl Ev.TimeoutKey
implEvent mgr = TimerImpl
    { timerStart = Ev.registerTimeout   mgr
    , timerStop  = Ev.unregisterTimeout mgr
    }

getTimerImpl :: (forall k. TimerImpl k -> IO r) -> IO r
getTimerImpl cont = do
    m <- Ev.getSystemEventManager
    case m of
        Nothing  -> cont implThreadId
        Just mgr -> cont (implEvent mgr)

-- | Create a new timer in the /pending/ state, which will expire in the given
-- number of microseconds.
newTimer :: Int -> IO Timer
newTimer t = getTimerImpl (\impl -> newTimerWith impl t)

newTimerWith :: TimerImpl a -> Int -> IO Timer
newTimerWith impl t = do
    var  <- newTVarIO False
    var' <- newTVarIO var
    k    <- timerStart impl t $ atomically $ writeTVar var True
    Timer var' impl <$> newMVar (Just k)

-- | Create a new timer in the /cleared/ state, meaning 'waitTimer' will block
-- indefinitely until you set it with 'setTimer'.
newTimer_ :: IO Timer
newTimer_ = getTimerImpl newTimerWith_

newTimerWith_ :: TimerImpl a -> IO Timer
newTimerWith_ impl = do
    var  <- newTVarIO False
    var' <- newTVarIO var
    Timer var' impl <$> newMVar Nothing

-- | Set an existing timer to expire in the given number of microseconds,
-- overriding any setting already in effect.  This will place the timer in the
-- /pending/ state.
setTimer :: Timer -> Int -> IO ()
setTimer (Timer var' impl mv) t =
    mask_ $ do
        -- Create a new timeout
        var <- newTVarIO False
        k   <- timerStart impl t $ atomically $ writeTVar var True

        -- Take the timer lock.  If we receive an asynchronous exception
        -- (which is possible even in mask_, because takeMVar is interruptible),
        -- free the timer we just created.
        m <- takeMVar mv `onException` timerStop impl k

        -- Make listeners see the new timeout status instead of the old one.
        atomically $ writeTVar var' var

        -- Restore the timer lock.
        putMVar mv (Just k)

        -- Free the old timeout, if one was present.
        maybe (return ()) (timerStop impl) m

-- | Cancel a pending expiration, so 'waitTimer' will block indefinitely.
-- This will place the timer in the /cleared/ state.
clearTimer :: Timer -> IO ()
clearTimer (Timer var' impl mv) =
    mask_ $ do
        var <- newTVarIO False
        m <- takeMVar mv
        atomically $ writeTVar var' var
        putMVar mv Nothing
        maybe (return ()) (timerStop impl) m

-- | Block until the 'Timer' /expires/.
waitTimer :: Timer -> STM ()
waitTimer timer = do
    expired <- tryWaitTimer timer
    if expired then return ()
               else retry

-- | Non-blocking version of 'waitTimer'.
-- Return 'True' if the 'Timer' has /expired/.
tryWaitTimer :: Timer -> STM Bool
tryWaitTimer (Timer v _ _) = readTVar v >>= readTVar

------------------------------------------------------------------------
-- Compatibility

compat_forkIOUnmasked :: IO () -> IO ThreadId
#if MIN_VERSION_base(4,4,0)
compat_forkIOUnmasked io = forkIOWithUnmask (\_ -> io)
#else
compat_forkIOUnmasked = forkIOUnmasked
#endif
