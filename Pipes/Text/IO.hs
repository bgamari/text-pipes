{-#LANGUAGE RankNTypes#-}


module Pipes.Text.IO 
   ( 
   -- * Text IO
   -- $textio
   
   -- * Caveats
   -- $caveats
   
   -- * Producers
   fromHandle
   , stdin
   , readFile
   -- * Consumers
   , toHandle
   , stdout
   , writeFile
   ) where

import qualified System.IO as IO
import Control.Exception (throwIO, try)
import Foreign.C.Error (Errno(Errno), ePIPE)
import qualified GHC.IO.Exception as G
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Pipes
import qualified Pipes.Safe.Prelude as Safe
import qualified Pipes.Safe as Safe
import Pipes.Safe (MonadSafe(..), Base(..))
import Prelude hiding (readFile, writeFile)

{- $textio
    Where pipes IO replaces lazy IO, @Producer Text m r@ replaces lazy 'Text'. 
    This module exports some convenient functions for producing and consuming 
    pipes 'Text' in IO, with caveats described below. 
    
    The main points are as in 
    <https://hackage.haskell.org/package/pipes-bytestring-1.0.0/docs/Pipes-ByteString.html Pipes.ByteString>
    
    An 'IO.Handle' can be associated with a 'Producer' or 'Consumer' according 
    as it is read or written to.

    To stream to or from 'IO.Handle's, one can use 'fromHandle' or 'toHandle'.  For
    example, the following program copies a document from one file to another:

> import Pipes
> import qualified Pipes.Text as Text
> import qualified Pipes.Text.IO as Text
> import System.IO
>
> main =
>     withFile "inFile.txt"  ReadMode  $ \hIn  ->
>     withFile "outFile.txt" WriteMode $ \hOut ->
>     runEffect $ Text.fromHandle hIn >-> Text.toHandle hOut

To stream from files, the following is perhaps more Prelude-like (note that it uses Pipes.Safe):

> import Pipes
> import qualified Pipes.Text as Text
> import qualified Pipes.Text.IO as Text
> import Pipes.Safe
>
> main = runSafeT $ runEffect $ Text.readFile "inFile.txt" >-> Text.writeFile "outFile.txt"

    You can stream to and from 'stdin' and 'stdout' using the predefined 'stdin'
    and 'stdout' pipes, as with the following \"echo\" program:

> main = runEffect $ Text.stdin >-> Text.stdout

-}


{- $caveats

    The operations exported here are a convenience, like the similar operations in 
    @Data.Text.IO@  (or rather, @Data.Text.Lazy.IO@, since, again, @Producer Text m r@ is
    'effectful text' and something like the pipes equivalent of lazy Text.)

    * Like the functions in @Data.Text.IO@, they attempt to work with the system encoding. 
  
    * Like the functions in @Data.Text.IO@, they are slower than ByteString operations. Where
       you know what encoding you are working with, use @Pipes.ByteString@ and @Pipes.Text.Encoding@ instead,
       e.g. @view utf8 Bytes.stdin@ instead of @Text.stdin@
  
    * Like the functions in  @Data.Text.IO@ , they use Text exceptions. 

   Something like 
 
>  view utf8 . Bytes.fromHandle :: Handle -> Producer Text IO (Producer ByteString m ()) 

   yields a stream of Text, and follows
   standard pipes protocols by reverting to (i.e. returning) the underlying byte stream
   upon reaching any decoding error. (See especially the pipes-binary package.) 

  By contrast, something like 

> Text.fromHandle :: Handle -> Producer Text IO () 

  supplies a stream of text returning '()', which is convenient for many tasks, 
  but violates the pipes @pipes-binary@ approach to decoding errors and 
  throws an exception of the kind characteristic of the @text@ library instead.


-}

{-| Convert a 'IO.Handle' into a text stream using a text size 
    determined by the good sense of the text library. Note with the remarks 
    at the head of this module that this
    is  slower than @view utf8 (Pipes.ByteString.fromHandle h)@
    but uses the system encoding and has other nice @Data.Text.IO@ features
-}

fromHandle :: MonadIO m => IO.Handle -> Producer Text m ()
fromHandle h =  go where
      go = do txt <- liftIO (T.hGetChunk h)
              if T.null txt then return ()
                            else do yield txt
                                    go 
{-# INLINABLE fromHandle#-}

-- | Stream text from 'stdin'
stdin :: MonadIO m => Producer Text m ()
stdin = fromHandle IO.stdin
{-# INLINE stdin #-}


{-| Stream text from a file in the simple fashion of @Data.Text.IO@ 

>>> runSafeT $ runEffect $ Text.readFile "hello.hs" >-> Text.map toUpper >-> hoist lift Text.stdout
MAIN = PUTSTRLN "HELLO WORLD"
-}

readFile :: MonadSafe m => FilePath -> Producer Text m ()
readFile file = Safe.withFile file IO.ReadMode fromHandle
{-# INLINE readFile #-}


{-| Stream text to 'stdout'

    Unlike 'toHandle', 'stdout' gracefully terminates on a broken output pipe.

    Note: For best performance, it might be best just to use @(for source (liftIO . putStr))@ 
    instead of @(source >-> stdout)@ .
-}
stdout :: MonadIO m => Consumer' Text m ()
stdout = go
  where
    go = do
        txt <- await
        x  <- liftIO $ try (T.putStr txt)
        case x of
            Left (G.IOError { G.ioe_type  = G.ResourceVanished
                            , G.ioe_errno = Just ioe })
                 | Errno ioe == ePIPE
                     -> return ()
            Left  e  -> liftIO (throwIO e)
            Right () -> go
{-# INLINABLE stdout #-}


{-| Convert a text stream into a 'Handle'

    Note: again, for best performance, where possible use 
    @(for source (liftIO . hPutStr handle))@ instead of @(source >-> toHandle handle)@.
-}
toHandle :: MonadIO m => IO.Handle -> Consumer' Text m r
toHandle h = for cat (liftIO . T.hPutStr h)
{-# INLINABLE toHandle #-}

{-# RULES "p >-> toHandle h" forall p h .
        p >-> toHandle h = for p (\txt -> liftIO (T.hPutStr h txt))
  #-}


-- | Stream text into a file. Uses @pipes-safe@.
writeFile :: (MonadSafe m) => FilePath -> Consumer' Text m ()
writeFile file = Safe.withFile file IO.WriteMode toHandle
{-# INLINE writeFile #-}
