{-# OPTIONS -XScopedTypeVariables -XRecordWildCards -XBangPatterns
            -XMagicHash -XUnboxedTuples
            -XDeriveDataTypeable
            -cpp #-}
{-# LANGUAGE GHCForeignImportPrim #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE UnliftedFFITypes #-}

{-# OPTIONS_HADDOCK prune #-}

{- | 

Module      : GHC.Packing
Copyright   : (c) Jost Berthold, 2010-2013,
License     : probably BSD3 (soon)
Maintainer  : berthold@diku.dk
Stability   : experimental
Portability : no (depends on GHC runtime support)

Serialisation of Haskell data structures using runtime system support.

Haskell heap structures can be serialised, capturing their current
state of evaluation, and deserialised later during the same program
run (effectively duplicating the data) or materialised on storage and
deserialised in a different run of the /same/ executable binary.

The feature can be used to implement message passing over a network
(which is where the runtime support originated), or for various
applications based on data persistence, for instance checkpointing and
memoisation.

There are two basic operations to serialise Haskell heap data:

> serialize, trySerialize :: a -> IO (Serialized a)

Both routines will throw @'PackException'@s when error conditions
occur inside the runtime system. In presence of concurrent threads,
the variant @'serialize'@ may block in case another thread is
evaluating data /referred to/ by the data to be
serialised. @'trySerialize'@ variant will never block, but instead
signal the condition as @'PackException'@ @'P_BLACKHOLE'@.  Other
exceptions thrown by these two operations indicate error conditions
within the runtime system support (see @'PackException'@).

The inverse operation to serialisation is

> deserialize :: Serialized a -> IO a

The data type @'Serialized' a@ includes a phantom type @a@ to ensure
type safety within one and the same program run. Type @a@ can be
polymorphic (at compile time, that is) when @Serialized a@ is not used
apart from being argument to @deserialize@.

The @Show@, @Read@, and @Binary@ instances of @Serialized a@ require an
additional @Typeable@ context (which requires @a@ to be monomorphic)
in order to implement dynamic type checks when parsing and deserialising
data from external sources.
Consequently, the @'PackException'@ type contains exceptions which indicate
parse errors and type/binary mismatch.

-}

module GHC.Packing
    ( -- * Serialisation Operations
      trySerialize
    , deserialize
      -- * Data Types
    , Serialized
    , PackException(..)
      -- * Serialisation and File I/O
    , encodeToFile 
    , decodeFromFile
    -- * Background Information
    
      -- $primitives
   )
    where

-- could make a compatibility layer for Eden-GHC-7.x (supports
-- serialize#) but we rather bail out here.
#if __GLASGOW_HASKELL__ != 708
#error This module assumes GHC-7.8
#endif

import GHC.IO ( IO(..) )
import GHC.Prim
import GHC.Exts ( Int(..))
import Data.Word( Word, Word64, Word32 )
import Data.Array.Base ( UArray(..), elems, listArray )
import Foreign.Storable ( sizeOf )
-- import GHC.Constants(TargetWord) would be nice...but is gone

-- Read and Show instances
import Text.Printf ( printf )
import Text.ParserCombinators.ReadP (sepBy1, many1, ReadP, munch,
    munch1, pfail, readP_to_S, satisfy, skipSpaces, string )
import Data.Char ( isDigit )

import Data.Binary ( Get, Binary(..), encode, decode, encodeFile, decodeFile )

-- for dynamic type checks when parsing
import Data.Typeable -- ( Typeable(..), typeOf )
import Data.Typeable.Internal (TypeRep(..))
import qualified GHC.Fingerprint

-- for a hash of the executable. Using GHC.Fingerprint.getFileHash
import GHC.Fingerprint(getFileHash)
import System.Environment
import System.IO.Unsafe
import qualified Data.ByteString as B
import Control.Monad( when )

-- for exceptions thrown by trySerialize
import qualified Control.Exception as E
  -- Typeable is also required for this

----------------------------------------------

-- replacement for the old GHC.Constants.TargetWord. This is a cheap
-- and incomplete hack. I could just use a configure script. Too bad
-- the comfortable GHC.Constants was removed.

-- And, actually, GHC uses machine word size (as Haskell 2010
-- spec. does not fix it) so this should not be necessary at all...
-- http://www.haskell.org/ghc/docs/7.6.3/html/users_guide/bugs-and-infelicities.html#haskell-98-2010-undefined
import Data.Word
#if x86_64_HOST_ARCH
type TargetWord = Word64
hexWordFmt = "0x%016x"
#elif i386_HOST_ARCH
type TargetWord = Word32
hexWordFmt = "0x%08x"
#elif powerpc_HOST_ARCH
#error Don't know word size of your Power-PC model
#else
#error Don't know the word size on your machine.
#endif

foreign import prim "stg_tryPack" tryPack# :: Any -> State# s -> (# State# s, Int#, ByteArray# #)
foreign import prim "stg_unpack" unpack# :: ByteArray# -> State# s -> (# State# s, Int#, a #)

-----------------------------------------------
-- Helper functions to compare types at runtime:
--   We use type "fingerprints" defined in GHC.Fingerprint.Type

-- This should ensure (as of GHC.7.8) that types with the same name
-- but different definition get different hashes.  (however, we also
-- require the executable to be exactly the same, so this is not
-- "strictly necessary" anyway.
-----------------------------------------------

-- Typeable context for dynamic type checks. 
-- | The module uses a custom GHC fingerprint type with its two Word64
--   fields, to be able to /read/ fingerprints
data FP = FP Word64 Word64 deriving (Read, Show, Eq)

-- | comparing 'FP's
matches :: Typeable a => a -> FP -> Bool
matches x (FP c1 c2) = f1 == c1 && f2 == c2
  where  (TypeRep (GHC.Fingerprint.Fingerprint f1 f2) _ _) = typeOf x

-- | creating an 'FP' from a GHC 'Fingerprint'
toFP :: GHC.Fingerprint.Fingerprint -> FP
toFP (GHC.Fingerprint.Fingerprint f1 f2) = FP f1 f2

-- | creating a type fingerprint
typeFP :: Typeable a => a -> FP
typeFP x = toFP fp
  where  (TypeRep fp _ _) = typeOf x

-----------------------------------------------
-- |  check that the program (executable) is
-- identical when packing and unpacking
-- It uses the fingerprint type from above (Read/Show instances required).
-- This 'FP' is computed once, by virtue of being a CAF (safe to
-- inline but inefficient).
{-# NOINLINE prgHash #-}
prgHash :: FP
prgHash = unsafePerformIO $ 
          getExecutablePath >>= getFileHash >>= return . toFP

-----------------------------------

-- | The type of Serialized data. Phantom type 'a' ensures that we do
-- not unpack rubbish. The hash of the executable is not needed here,
-- but only when /externalising/ data (writing to disk, for instance).
data Serialized a = Serialized { packetData :: ByteArray# }

-- | Non-blocking serialisation routine using @'PackException'@s to
-- signal errors. This version does not block the calling thread when
-- a black hole is found, but instead signals the condition by the
-- @'P_BLACKHOLE'@ exception.
trySerialize :: a -> IO (Serialized a) -- throws PackException (RTS)
trySerialize x = do r <- trySer_ x -- a more verbose way of writing it...
                    case r of
                      Left err     -> E.throw err
                      Right packed -> return packed
-- using a helper function
trySer_ :: a -> IO (Either PackException (Serialized a))
trySer_ x = IO (\s -> case tryPack# (unsafeCoerce# x :: Any) s of
                        (# s', 0#, bArr# #) -> (# s', Right (Serialized { packetData=bArr# }) #)
                        (# s', n#, _ #)     -> (# s', Left (tagToEnum# n# ) #)
               )

-- | Deserialisation function. May throw @'PackException'@ @'P_GARBLED'@
deserialize :: Serialized a -> IO a  -- throws PackException (garbled)
deserialize ( Serialized{..} ) = IO $ 
              \s -> case unpack# packetData s of
                      (# s', 0#, x #) -> (# s', x #)
                      (# s', n#, _ #) -> (# s', E.throw ((tagToEnum# n#)::PackException) #) 

--------------------------------------------------------

-- | Packing exception codes, matching error codes implemented in the
-- runtime system or describing errors which can occur within Haskell.
data PackException = P_SUCCESS      -- | all fine, ==0. We do not expect this one to occur.
     -- Error codes from the runtime system: (how can I teach haddock to make this a heading?)
     | P_BLACKHOLE    -- ^ RTS: packing hit a blackhole (not blocking thread)
     | P_NOBUFFER     -- ^ RTS: buffer too small (increase RTS buffer with -qQ<size>)
     | P_CANNOT_PACK  -- ^ RTS: found a closure that cannot be packed (MVar, TVar)
     | P_UNSUPPORTED  -- ^ RTS: hit unsupported closure type (implementation missing)
     | P_IMPOSSIBLE   -- ^ RTS: hit impossible case (stack frame, message,...RTS bug!)
     | P_GARBLED       -- ^ RTS: invalid data for deserialisation
     -- Error codes from inside Haskell
     | P_ParseError     -- ^ Haskell: Packet data could not be parsed
     | P_BinaryMismatch -- ^ Haskell: Executable binaries do not match
     | P_TypeMismatch   -- ^ Haskell: Packet data encodes unexpected type
     deriving (Eq, Ord, Typeable)
-- enum.. we will use tagtoenum# later

instance Show PackException where
    show P_SUCCESS = "No error." -- we do not expect to see this
    show P_BLACKHOLE     = "Packing hit a blackhole"
    show P_NOBUFFER      = "Buffer too small (RTS buffer can be increased with -qQ<size>)"
    show P_CANNOT_PACK   = "Data contain a closure that cannot be packed (MVar, TVar)"
    show P_UNSUPPORTED   = "Contains an unsupported closure type (whose implementation is missing)"
    show P_IMPOSSIBLE    = "An impossible case happened (stack frame, message). This is probably a bug."
    show P_GARBLED       = "Garbled data for deserialisation"
    show P_ParseError     = "Packet parse error"
    show P_BinaryMismatch = "Executable binaries do not match"
    show P_TypeMismatch   = "Packet data has unexpected type"
--    show other           = "Packing error. TODO: define strings for more specific cases."

instance E.Exception PackException

-----------------------------------------------
-- Show Instance for packets: 
-- | prints packet as Word array in 4 columns (/Word/ meaning the
-- machine word size), and additionally includes Fingerprint hash
-- values for executable binary and type.
instance Typeable a => Show (Serialized a) where
    show (Serialized {..} )
        = "Serialization Packet, size " ++ show size
          ++ ", program " ++ show prgHash ++ "\n"
          ++ ", type " ++ show t ++ "\n"
          ++ showWArray (UArray 0 (size-1) size packetData )
        where size = case sizeofByteArray# packetData of
                          sz# -> (I# sz# ) `div` sizeOf(undefined::Word)
              t    = typeFP ( undefined :: a )

-- Helper to show a serialized structure as a packet (Word Array)
showWArray :: UArray Int TargetWord -> String
showWArray arr = unlines [ show i ++ ":" ++ unwords (map showH row)
                         | (i,row) <- zip  [0,4..] elRows ]
    where showH w = -- "\t0x" ++ showHex w " "
                    printf ('\t':hexWordFmt) w
          elRows = takeEach4 (elems arr)
          
          takeEach4 :: [a] -> [[a]]
          takeEach4 [] = []
          takeEach4 xs = first:takeEach4 rest
            where (first,rest) = splitAt 4 xs

-----------------------------------------------
-- | Reads the format generated by the (@'Show'@) instance, checks
--   hash values for executable and type and parses exactly as much as
--   the included data size announces.
instance Typeable a => Read (Serialized a)
    -- using ReadP parser (base-4.x), eats
    where readsPrec _ input
           = case parseP input of
              []  -> E.throw P_ParseError -- no parse
              [((sz,tp,dat),r)]
                  -> let !(UArray _ _ _ arr# ) = listArray (0,sz-1) dat
                         t = typeFP (undefined::a)
                     in if t == tp
                              then [(Serialized arr# , r)]
                              else E.throw P_TypeMismatch
              other-> E.throw P_ParseError
                       -- ambiguous parse for packet

-- Packet Parser: read header with size and type, then iterate over
-- array values, reading several hex words in one row, separated by
-- tab and space. Packet size needed to avoid returning a prefix.
-- Could also consume other formats of the array (not implemented).

-- returns: (data size in words, type fingerprint, array values)      
parseP :: ReadS (Int, FP, [TargetWord]) 
parseP = readP_to_S $
         do string "Serialization Packet, size "
            sz_str <- munch1 isDigit
            let sz = read sz_str::Int
            string ", program "
            h  <- munch1 (not . (== '\n'))
            when (read h /= prgHash) (E.throw P_BinaryMismatch)
              -- executables do not match. No ambiguous parses here,
              -- so just throw; otherwise we would only pfail.
            newline
            string ", type "
            tp <- munch1 (not . (== '\n'))
            newline
            let startRow = do { many1 digit; colon; tabSpace }
                row = do { startRow; sepBy1 hexNum tabSpace }
            valss <- sepBy1 row newline
            skipSpaces -- eat remaining spaces
            let vals = concat valss
                l    = length vals
            -- filter out wrong lengths:
            if (sz /= length vals) then pfail
                                   else return (sz, read tp, vals)

digit = satisfy isDigit
colon = satisfy (==':')
tabSpace = munch1 ( \x -> x `elem` " \t" )
newline = munch1 (\x -> x `elem` " \n")

hexNum :: ReadP TargetWord -- we are fixing the type to what we need
hexNum = do string "0x"
            ds <- munch hexDigit
            return (read ("0x" ++ ds))
  where hexDigit = (\x -> x `elem` "0123456789abcdefABCDEF")

------------------------------------------------------------------
-- | Binary instance for fingerprint data (encoding TypeRep and
--   executable in binary-encoded @Serialized a@)
instance Binary FP where
  put (FP f1 f2) = do put f1
                      put f2
  get            = do f1 <- get :: Get Word64
                      f2 <- get :: Get Word64
                      return (FP f1 f2)

-- | The binary format of @'Serialized' a@ data includes FingerPrint
--   hash values for type and executable binary, which are checked
--   when reading Serialized data back in using @get@.
instance Typeable a => Binary (Serialized a) where
    -- We make our life simple and construct/deconstruct Word
    -- (U)Arrays, quite as we did in the Show/Read instances.
    put (Serialized bArr#)
        = do put prgHash
             put (typeFP (undefined :: a))
             let arr    = UArray 0 (sz-1) sz bArr# :: UArray Int TargetWord
                 sz     = case sizeofByteArray# bArr# of
                            sz# -> (I# sz# ) `div` sizeOf(undefined::TargetWord)
             put arr
    get = do hash   <- get :: Get FP
             when (hash /= prgHash) 
               (E.throw P_BinaryMismatch) 
             -- executables do not match
             tp <- get :: Get FP
             when (tp /= typeFP (undefined :: a))
               (E.throw P_TypeMismatch)
                -- Type error during packet parse
             uarr   <- get :: Get (UArray Int TargetWord)
             let !(UArray _ _ sz bArr#) = uarr
             return ( Serialized bArr# )

-- | Write serialised binary data directly to a file.
encodeToFile :: Typeable a => FilePath -> a -> IO ()
encodeToFile path x = trySerialize x >>= encodeFile path

-- | Directly read binary serialised data from a file. Catches
--   exceptions from decoding the file and re-throws @'ParseError'@s
decodeFromFile :: Typeable a => FilePath -> IO a
decodeFromFile path = (decodeFile path >>= deserialize) 
                      `E.catch` (\(e::E.ErrorCall) -> E.throw P_ParseError)

----------------------------------------
-- digressive documentation

{- $primitives

The functionality exposed by this module builds on serialisation of
Haskell heap graph structures, first implemented in the context of
implementing the GpH implementation GUM (Graph reduction on a 
Unified Memory System) and later adopted by the implementation of
Eden. Independent of its evaluation state, data and thunks can be
transferred between the (independent) heaps of several running Haskell
runtime system instances which execute the same executable.

The idea to expose the heap data serialisation functionality 
(often called /packing/) to Haskell by itself was first described in 
 Jost Berthold. /Orthogonal Serialisation for Haskell/.
 In Jurriaan Hage and Marco Morazan, editors, 
 /IFL'10, 22nd Symposium on Implementation and Application of 
 Functional Languages/, Springer LNCS 6647, pages 38-53, 2011.
This paper can be found at 
<http://www.mathematik.uni-marburg.de/~eden/papers/mainIFL10-withCopyright.pdf>,
the original publication is available at 
<http://www.springerlink.com/content/78642611n7623551/>.

The core runtime support consists of just two operations:
(slightly paraphrasing the way in which GHC implements the IO monad here)

> serialize#   :: a -> IO ByteArray# -- OUTDATED, see below
> deserialize# :: ByteArray# -> IO a -- which is actually pure from a mathematical POW

However, these operations are completely unsafe with respect to Haskell
types, and may fail at runtime for various other reasons as well. 
Type safety can be established by a phantom type, but needs to be checked
at runtime when the resulting data structure is externalised (for instance,
saved to a file). Besides prohibiting unprotected type casts, another
restriction that needs to be explicitly checked in this case is that 
different programs cannot exchange data by this serialisation. When data are
serialised during execution, they can only be deserialised by exactly the 
same executable binary because they contain code pointers that will change
even by recompilation.

Other failures can occur because of the runtime system's limitations, 
and because some mutable data types are not allowed to be serialised.
A newer API therefore suggests additions towards exception handling
and better usability.
The original primitive @'serialize'@ is modified and now returns error
codes, leading to the following type (again paraphrasing):

> serialize# :: a -> IO ( Int# , ByteArray# )

where the @Int#@ encodes potential error conditions returned by the runtime.

A second primitive operation has been defined, which considers the presence
of concurrent evaluations of the serialised data by other threads:

> trySerialize# :: a -> IO ( Int# , ByteArray# )

Further to returning error codes, this primitive operation will not block
the calling thread when the serialisation encounters a blackhole in the
heap. While blocking is a perfectly acceptable behaviour (making packing
behave analogous to evaluation wrt. concurrency), the @'trySerialize'@
variant allows one to explicitly control it and avoid becoming unresponsive.

as well, and differs from @trySerialize@ in that
it blocks the calling thread when a blackhole is found during serialisation.

The Haskell layer and its types protect the interface function @'deserialize'@
from being applied to  grossly wrong data (by checking a fingerprint of the 
executable and the expected type), but deserialisation is fragile by nature
(unpacking code pointers and data).
The primitive operation in the runtime system will only detect grossly wrong
formats, and the primitive will return error code @'P_GARBLED'@ when data
corruption is detected.

> deserialize# :: ByteArray# -> IO ( Int# , a )
-}
