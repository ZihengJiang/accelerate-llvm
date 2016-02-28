{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.Array.Data
-- Copyright   : [2014..2015] Trevor L. McDonell
--               [2014..2014] Vinod Grover (NVIDIA Corporation)
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.LLVM.Array.Data (

  Remote(..),
  newRemote,
  useRemote,    useRemoteAsync,
  copyToRemote, copyToRemoteAsync,
  copyToHost,   copyToHostAsync,
  copyToPeer,   copyToPeerAsync,

  runIndexArray,
  runArray,

  module Data.Array.Accelerate.Array.Data,

) where

-- accelerate
import Data.Array.Accelerate.Array.Data
import Data.Array.Accelerate.Array.Sugar

import Data.Array.Accelerate.LLVM.State
import Data.Array.Accelerate.LLVM.Async

-- standard library
import Control.Monad
import Control.Monad.Trans
import Data.Typeable
import Foreign.C.Types
import Foreign.Ptr
import Foreign.Storable


class Async arch => Remote arch where

  -- | Allocate a new uninitialised array on the remote device.
  --
  {-# INLINEABLE allocateRemote #-}
  allocateRemote :: (Shape sh, Elt e) => sh -> LLVM arch (Array sh e)
  allocateRemote sh = liftIO $ allocateArray sh

  -- | Use the given immutable array on the remote device. Since the source
  -- array is immutable, the allocator can evict and re-upload the data as
  -- necessary without copy-back.
  --
  {-# INLINEABLE useRemoteR #-}
  useRemoteR :: (ArrayElt e, ArrayPtrs e ~ Ptr a, Storable a, Typeable a, Typeable e)
             => Int
             -> Maybe (StreamR arch)
             -> ArrayData e
             -> LLVM arch ()
  useRemoteR _ _ _ = return ()

  -- | Upload a section of an array from the host to the remote device. Only the
  -- elements between the given indices (inclusive left, exclusive right) are
  -- transferred.
  --
  {-# INLINEABLE copyToRemoteR #-}
  copyToRemoteR :: (ArrayElt e, ArrayPtrs e ~ Ptr a, Storable a, Typeable a, Typeable e)
                => Int
                -> Int
                -> Maybe (StreamR arch)
                -> ArrayData e -> LLVM arch ()
  copyToRemoteR _ _ _ _ = return ()

  -- | Copy a section of an array from the remote device back to the host. The
  -- elements between the given indices (inclusive left, exclusive right) are
  -- transferred.
  --
  {-# INLINEABLE copyToHostR #-}
  copyToHostR :: (ArrayElt e, ArrayPtrs e ~ Ptr a, Storable a, Typeable a, Typeable e)
              => Int
              -> Int
              -> Maybe (StreamR arch)
              -> ArrayData e
              -> LLVM arch ()
  copyToHostR _ _ _ _ = return ()

  -- | Copy a section of an array between two remote instances of the same type.
  -- This may be more efficient than copying to the host and then to the second
  -- remote instance (e.g. DMA between two CUDA devices). The elements between
  -- the given indices (inclusive left, exclusive right) are transferred.
  --
  {-# INLINEABLE copyToPeerR #-}
  copyToPeerR :: (ArrayElt e, ArrayPtrs e ~ Ptr a, Storable a, Typeable a, Typeable e)
              => Int
              -> Int
              -> arch
              -> Maybe (StreamR arch)
              -> ArrayData e
              -> LLVM arch ()
  copyToPeerR _ _ _ _ _ = return ()

  -- | Read a single element from the array at a given row-major index
  --
  {-# INLINEABLE indexRemote #-}
  indexRemote :: Array sh e -> Int -> LLVM arch e
  indexRemote (Array _ adata) i = return . toElt $! unsafeIndexArrayData adata i


-- CPP hackery to generate the cases where we dispatch to the worker function handling
-- elementary types.
--
-- TODO: Turn me into Template Haskell so that I can be exported and reused.
--
#define mkPrimDispatch(dispatcher,worker)                                       \
; dispatcher ArrayEltRint     = worker                                          \
; dispatcher ArrayEltRint8    = worker                                          \
; dispatcher ArrayEltRint16   = worker                                          \
; dispatcher ArrayEltRint32   = worker                                          \
; dispatcher ArrayEltRint64   = worker                                          \
; dispatcher ArrayEltRword    = worker                                          \
; dispatcher ArrayEltRword8   = worker                                          \
; dispatcher ArrayEltRword16  = worker                                          \
; dispatcher ArrayEltRword32  = worker                                          \
; dispatcher ArrayEltRword64  = worker                                          \
; dispatcher ArrayEltRfloat   = worker                                          \
; dispatcher ArrayEltRdouble  = worker                                          \
; dispatcher ArrayEltRbool    = worker                                          \
; dispatcher ArrayEltRchar    = worker                                          \
; dispatcher ArrayEltRcshort  = worker                                          \
; dispatcher ArrayEltRcushort = worker                                          \
; dispatcher ArrayEltRcint    = worker                                          \
; dispatcher ArrayEltRcuint   = worker                                          \
; dispatcher ArrayEltRclong   = worker                                          \
; dispatcher ArrayEltRculong  = worker                                          \
; dispatcher ArrayEltRcllong  = worker                                          \
; dispatcher ArrayEltRcullong = worker                                          \
; dispatcher ArrayEltRcfloat  = worker                                          \
; dispatcher ArrayEltRcdouble = worker                                          \
; dispatcher ArrayEltRcchar   = worker                                          \
; dispatcher ArrayEltRcschar  = worker                                          \
; dispatcher ArrayEltRcuchar  = worker                                          \
; dispatcher _                = error "mkPrimDispatcher: not primitive"


-- | Allocate a new uninitialised array on the remote device
--



-- | Create a new array from its representation on the host, and upload it to
-- a new remote array.
--
{-# INLINEABLE newRemote #-}
newRemote
    :: (Remote arch, Shape sh, Elt e)
    => sh
    -> (sh -> e)
    -> LLVM arch (Array sh e)
newRemote sh f =
  useRemote $! newArray sh f


-- | Upload an immutable array from the host to the remote device.
--
{-# INLINEABLE useRemote #-}
useRemote :: (Remote arch, Arrays a) => a -> LLVM arch a
useRemote arrs = do
  runArrays arrs $ \arr@Array{} -> let n = size (shape arr)
                                   in  runArray arr (useRemoteR n Nothing)
  return arrs

-- | Upload an immutable array from the host to the remote device,
-- asynchronously.
--
{-# INLINEABLE useRemoteAsync #-}
useRemoteAsync :: (Remote arch, Arrays a) => StreamR arch -> a -> LLVM arch (AsyncR arch a)
useRemoteAsync stream arrs = do
  runArrays arrs $ \arr@Array{} -> do
    let n = size (shape arr)
    runArray arr $ \ad          -> do
      async      $ \s           -> do
        useRemoteR n (Just s) ad
        after stream =<< waypoint s
  --
  e <- waypoint stream      -- TLM: assuming that adding events to a stream counts as things to wait for
  return $ AsyncR e arrs

-- | Uploading existing arrays from the host to the remote device
--
{-# INLINEABLE copyToRemote #-}
copyToRemote :: (Remote arch, Arrays a) => a -> LLVM arch a
copyToRemote arrs = do
  runArrays arrs $ \arr@Array{} -> let n = size (shape arr)
                                   in runArray arr (copyToRemoteR 0 n Nothing)
  return arrs

-- | Upload an existing array to the remote device, asynchronously.
--
{-# INLINEABLE copyToRemoteAsync #-}
copyToRemoteAsync :: (Remote arch, Arrays a) => StreamR arch -> a -> LLVM arch (AsyncR arch a)
copyToRemoteAsync stream arrs = do
  runArrays arrs $ \arr@Array{} -> do
    let n = size (shape arr)
    runArray arr $ \ad          -> do
      async      $ \s           -> do
        copyToRemoteR 0 n (Just s) ad
        after stream =<< waypoint s
  --
  e <- waypoint stream
  return $! AsyncR e arrs

-- | Copy an array from the remote device to the host.
--
{-# INLINEABLE copyToHost #-}
copyToHost :: (Remote arch, Arrays a) => a -> LLVM arch a
copyToHost arrs = do
  runArrays arrs $ \arr@Array{} -> let n = size (shape arr)
                                   in  runArray arr (copyToHostR 0 n Nothing)
  return arrs

-- | Copy an array from the remote device to the host, asynchronously
--
{-# INLINEABLE copyToHostAsync #-}
copyToHostAsync :: (Remote arch, Arrays a) => StreamR arch -> a -> LLVM arch (AsyncR arch a)
copyToHostAsync stream arrs = do
  runArrays arrs $ \arr@Array{} -> do
    let n = size (shape arr)
    runArray arr $ \ad          -> do
      async      $ \s           -> do
        copyToHostR 0 n (Just s) ad
        after stream =<< waypoint s
  --
  e <- waypoint stream
  return $! AsyncR e arrs


-- | Copy arrays between two remote instances of the same type. This may be more
-- efficient than copying to the host and then to the second remote instance
-- (e.g. DMA between CUDA devices).
--
{-# INLINEABLE copyToPeer #-}
copyToPeer :: (Remote arch, Arrays a) => arch -> a -> LLVM arch a
copyToPeer peer arrs = do
  runArrays arrs $ \arr@Array{} -> let n = size (shape arr)
                                   in  runArray arr (copyToPeerR 0 n peer Nothing)
  return arrs

-- | As 'copyToPeer', asynchronously.
--
{-# INLINEABLE copyToPeerAsync #-}
copyToPeerAsync :: (Remote arch, Arrays a) => arch -> StreamR arch -> a -> LLVM arch (AsyncR arch a)
copyToPeerAsync peer stream arrs = do
  runArrays arrs $ \arr@Array{} -> do
    let n = size (shape arr)
    runArray arr $ \ad          -> do
      async      $ \s           -> do
        copyToPeerR 0 n peer (Just s) ad
        after stream =<< waypoint s
  --
  e <- waypoint stream
  return $! AsyncR e arrs


-- Helpers for traversing the Arrays data structure
-- ------------------------------------------------

-- |Read a single element from an array at the given row-major index.
--
{-# INLINEABLE runIndexArray #-}
runIndexArray
    :: forall m sh e. Monad m
    => (forall e a. (ArrayElt e, ArrayPtrs e ~ Ptr a, Storable a, Typeable a, Typeable e) => ArrayData e -> Int -> m a)
    -> Array sh e
    -> Int
    -> m e
runIndexArray worker (Array _ adata) i = toElt `liftM` indexR arrayElt adata
  where
    indexR :: ArrayEltR a -> ArrayData a -> m a
    indexR ArrayEltRunit             _  = return ()
    indexR (ArrayEltRpair aeR1 aeR2) ad = liftM2 (,) (indexR aeR1 (fstArrayData ad))
                                                     (indexR aeR2 (sndArrayData ad))
    --
    indexR ArrayEltRint              ad = worker ad i
    indexR ArrayEltRint8             ad = worker ad i
    indexR ArrayEltRint16            ad = worker ad i
    indexR ArrayEltRint32            ad = worker ad i
    indexR ArrayEltRint64            ad = worker ad i
    indexR ArrayEltRword             ad = worker ad i
    indexR ArrayEltRword8            ad = worker ad i
    indexR ArrayEltRword16           ad = worker ad i
    indexR ArrayEltRword32           ad = worker ad i
    indexR ArrayEltRword64           ad = worker ad i
    indexR ArrayEltRfloat            ad = worker ad i
    indexR ArrayEltRdouble           ad = worker ad i
    indexR ArrayEltRchar             ad = worker ad i
    indexR ArrayEltRcshort           ad = CShort  `liftM` worker ad i
    indexR ArrayEltRcushort          ad = CUShort `liftM` worker ad i
    indexR ArrayEltRcint             ad = CInt    `liftM` worker ad i
    indexR ArrayEltRcuint            ad = CUInt   `liftM` worker ad i
    indexR ArrayEltRclong            ad = CLong   `liftM` worker ad i
    indexR ArrayEltRculong           ad = CULong  `liftM` worker ad i
    indexR ArrayEltRcllong           ad = CLLong  `liftM` worker ad i
    indexR ArrayEltRcullong          ad = CULLong `liftM` worker ad i
    indexR ArrayEltRcchar            ad = CChar   `liftM` worker ad i
    indexR ArrayEltRcschar           ad = CSChar  `liftM` worker ad i
    indexR ArrayEltRcuchar           ad = CUChar  `liftM` worker ad i
    indexR ArrayEltRcfloat           ad = CFloat  `liftM` worker ad i
    indexR ArrayEltRcdouble          ad = CDouble `liftM` worker ad i
    indexR ArrayEltRbool             ad = toBool  `liftM` worker ad i
      where
        toBool 0 = False
        toBool _ = True


-- | Generalised function to traverse the Arrays structure
--
{-# INLINE runArrays #-}
runArrays
    :: forall m arrs. (Monad m, Arrays arrs)
    => arrs
    -> (forall sh e. Array sh e -> m ())
    -> m ()
runArrays arrs worker = runR (arrays arrs) (fromArr arrs)
  where
    runR :: ArraysR a -> a -> m ()
    runR ArraysRunit             ()             = return ()
    runR ArraysRarray            arr            = worker arr
    runR (ArraysRpair aeR1 aeR2) (arrs1, arrs2) = runR aeR1 arrs1 >> runR aeR2 arrs2


-- | Generalised function to traverse the ArrayData structure with one
-- additional argument
--
{-# INLINE runArray #-}
runArray
    :: forall m sh e. Monad m
    => Array sh e
    -> (forall e' p. (ArrayElt e', ArrayPtrs e' ~ Ptr p, Storable p, Typeable p, Typeable e') => ArrayData e' -> m ())
    -> m ()
runArray (Array _ adata) worker = runR arrayElt adata
  where
    runR :: ArrayEltR e' -> ArrayData e' -> m ()
    runR ArrayEltRunit             _  = return ()
    runR (ArrayEltRpair aeR1 aeR2) ad = runR aeR1 (fstArrayData ad) >>
                                        runR aeR2 (sndArrayData ad)
    runR aer                       ad = runW aer ad
    --
    runW :: ArrayEltR e' -> ArrayData e' -> m ()
    mkPrimDispatch(runW, worker)

