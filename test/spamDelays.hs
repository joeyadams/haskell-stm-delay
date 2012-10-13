import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.Delay
import Control.Monad
import System.IO

spamDelays i = do
    putStr $ "\r" ++ show i
    hFlush stdout
    d <- newDelay 100000000
    threadDelay 1000
    cancelDelay d
    spamDelays $! i+1

main = spamDelays 1
