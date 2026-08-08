{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : HtmlSanitizer
-- Description : Clean HTML of constructs that can lead to Cross-Site Scripting.
--
-- A thin binding over the monorepo's ONE shared native engine —
-- @core\/native\/libhtmlsanitizer.so@, compiled from pure Aether. It contains
-- __no sanitizer logic__: every function here marshals to an
-- @aether_hs_embed_*@ call across the C ABI described in @core\/embed.ae@. One
-- engine, one set of behaviours, N language surfaces.
--
-- @
-- import qualified Data.ByteString.Char8 as C
-- import HtmlSanitizer
--
-- main :: IO ()
-- main = withSanitizer $ \\s -> do
--     clean <- sanitize s \"\<div onclick=\\\"alert(1)\\\"\>Hello \<script\>evil()\<\/script\>\<\/div\>\"
--     C.putStrLn clean
--     -- \<div\>Hello \<\/div\>
-- @
--
-- == Strings
--
-- Everything is 'B.ByteString', holding UTF-8 bytes. The engine speaks UTF-8;
-- passing bytes straight through is lossless and keeps the dependency set to
-- @base@ + @bytestring@. If you work in 'Data.Text.Text', encode with
-- @Data.Text.Encoding.encodeUtf8@ at the boundary.
--
-- == Lifetime
--
-- A 'Sanitizer' owns a native handle and a set of Haskell 'FunPtr' stubs.
-- Neither is garbage-collected, so 'close' is not optional — prefer
-- 'withSanitizer', which closes on the way out even if the body throws.
-- 'close' is idempotent, and every operation on a closed sanitizer throws
-- 'SanitizerClosed' rather than dereferencing a freed pointer.
--
-- A 'Sanitizer' is __not__ safe for concurrent use: the native handle carries
-- mutable policy and hook state. Use one per thread, or guard it with an
-- 'Control.Concurrent.MVar.MVar'.
module HtmlSanitizer
  ( -- * The sanitizer
    Sanitizer
  , new
  , close
  , withSanitizer
  , isClosed

    -- * Sanitizing
  , sanitize
  , sanitizeWithBase
  , sanitizeDocument
  , sanitizeDocumentWithBase

    -- * One-shots
  , sanitizeOnce
  , sanitizeDocumentOnce

    -- * Flags
  , setKeepChildNodes
  , getKeepChildNodes
  , setAllowDataAttributes
  , getAllowDataAttributes

    -- * Policy lists
  , N.Which (..)
  , allow
  , allowMany
  , disallow
  , isAllowed
  , clearList
  , countList
  , itemAt
  , items
  , sortedItems

    -- * Callbacks
    -- $callbacks
  , onRemovingTag
  , onRemovingAttribute
  , onRemovingStyle
  , onRemovingComment
  , onPostProcessNode
  , onPostProcessDom
  , onFilterUrl
  , clearHooks

    -- * DOM access (inside a callback only)
  , Node
  , Attribute
  , N.NodeKind (..)
  , N.Reason (..)
  , nodeKind
  , nodeName
  , nodeValue
  , nodeChildCount
  , nodeChildAt
  , nodeChildren
  , nodeParent
  , nodeAttrCount
  , nodeAttrAt
  , nodeAttributes
  , attrName
  , attrValue
  , setAttrValue

    -- * Introspection
  , abiVersion

    -- * Errors
  , SanitizerError (..)
  ) where

import Control.Exception (Exception, bracket, throwIO)
import Control.Monad (forM, when)
import qualified Data.ByteString as B
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Maybe (catMaybes)
import Foreign.C.Types (CInt)
import Foreign.Ptr (FunPtr, Ptr, castFunPtrToPtr, freeHaskellFunPtr, nullPtr)

import qualified HtmlSanitizer.Native as N

-- ---------------------------------------------------------------------------
-- The handle
-- ---------------------------------------------------------------------------

-- | An opaque native sanitizer, plus the Haskell-side state that has to live
-- exactly as long as it.
--
-- @sanHooks@ is the important field and the reason this type is not just a
-- newtype over a 'Ptr'. Every 'FunPtr' produced by a @foreign import ccall
-- \"wrapper\"@ is a heap-allocated executable stub that pins the Haskell
-- closure behind it. The GC does not know the engine is holding a pointer to
-- it, and it is not released when the Haskell value goes out of scope. So:
--
--   * we __retain__ every stub we register here, for as long as the engine
--     could call it, and
--   * we __free__ each exactly once, in 'close', with 'freeHaskellFunPtr'.
--
-- Getting this wrong is the classic Haskell FFI bug. Dropping the FunPtr
-- silently leaks the stub; freeing it while the engine still holds it turns
-- the next callback into a jump through reclaimed memory.
--
-- Note the ordering constraint in 'close': the hooks must be unregistered
-- (or the handle freed) __before__ the stubs are released. We free the native
-- handle first, which drops the engine's reference to every hook, and only
-- then free the stubs.
data Sanitizer = Sanitizer
  { sanHandle :: IORef (Ptr ())
    -- ^ The engine handle, or 'nullPtr' once closed.
  , sanHooks :: IORef [IO ()]
    -- ^ Deferred 'freeHaskellFunPtr' actions, newest first. One per registered
    -- stub, including superseded ones — replacing a hook does not free the old
    -- stub immediately, because the engine may still be mid-call on it from
    -- another (mis)use; deferring to 'close' is the conservative choice and
    -- costs a few dozen bytes per re-registration.
  }

-- | Things that can go wrong on this side of the boundary. Sanitizing itself
-- does not fail — the engine returns a cleaned string or an empty one.
data SanitizerError
  = SanitizerAllocFailed
    -- ^ @aether_hs_embed_new@ returned null.
  | SanitizerClosed
    -- ^ An operation was attempted after 'close'.
  deriving (Eq, Show)

instance Exception SanitizerError

-- | Create a sanitizer with the engine's secure defaults populated.
--
-- The caller owns it: 'close' it, or better, use 'withSanitizer'.
new :: IO Sanitizer
new = do
  h <- N.aether_hs_embed_new
  when (h == nullPtr) $ throwIO SanitizerAllocFailed
  Sanitizer <$> newIORef h <*> newIORef []

-- | Release the native handle and every callback stub. Idempotent.
--
-- Order matters and is deliberate: freeing the handle first tears down the
-- engine's hook boxes, so by the time we 'freeHaskellFunPtr' the stubs, nothing
-- can call them.
close :: Sanitizer -> IO ()
close s = do
  h <- atomicModifyIORef' (sanHandle s) (\p -> (nullPtr, p))
  when (h /= nullPtr) $ N.aether_hs_embed_free h
  -- Take the list even if the handle was already null, so a double close is a
  -- genuine no-op rather than a double free.
  frees <- atomicModifyIORef' (sanHooks s) (\fs -> ([], fs))
  sequence_ frees

-- | 'bracket' 'new' 'close' — the way you should normally acquire one.
withSanitizer :: (Sanitizer -> IO a) -> IO a
withSanitizer = bracket new close

-- | Has 'close' already run?
isClosed :: Sanitizer -> IO Bool
isClosed s = (== nullPtr) <$> readIORef (sanHandle s)

-- | Read the live handle, or throw. Every ABI-touching function goes through
-- this, so a use-after-close is an exception rather than a segfault.
withHandle :: Sanitizer -> (Ptr () -> IO a) -> IO a
withHandle s act = do
  h <- readIORef (sanHandle s)
  when (h == nullPtr) $ throwIO SanitizerClosed
  act h

-- | Remember a stub so it outlives the engine's reference to it, and is freed
-- exactly once at 'close'.
retainStub :: Sanitizer -> FunPtr a -> IO ()
retainStub s fp = atomicModifyIORef' (sanHooks s) (\fs -> (freeHaskellFunPtr fp : fs, ()))

-- ---------------------------------------------------------------------------
-- Sanitizing
-- ---------------------------------------------------------------------------

-- | Clean an HTML fragment. Relative URLs are left alone.
sanitize :: Sanitizer -> B.ByteString -> IO B.ByteString
sanitize s html = sanitizeWithBase s html B.empty

-- | Clean an HTML fragment, resolving relative URLs against a base URL.
--
-- @
-- sanitizeWithBase s \"\<img src=\\\"logo.png\\\"\>\" \"https:\/\/example.com\"
-- -- \<img src=\"https:\/\/example.com\/logo.png\"\>
-- @
sanitizeWithBase :: Sanitizer -> B.ByteString -> B.ByteString -> IO B.ByteString
sanitizeWithBase s html base =
  withHandle s $ \h ->
    N.withUtf8 html $ \cHtml ->
      N.withUtf8 base $ \cBase ->
        N.takeString =<< N.aether_hs_embed_sanitize h cHtml cBase

-- | Clean a full HTML document. Currently the same engine path as 'sanitize';
-- it is a distinct export so the two-method surface stays available.
sanitizeDocument :: Sanitizer -> B.ByteString -> IO B.ByteString
sanitizeDocument s html = sanitizeDocumentWithBase s html B.empty

-- | 'sanitizeDocument' with a base URL.
sanitizeDocumentWithBase :: Sanitizer -> B.ByteString -> B.ByteString -> IO B.ByteString
sanitizeDocumentWithBase s html base =
  withHandle s $ \h ->
    N.withUtf8 html $ \cHtml ->
      N.withUtf8 base $ \cBase ->
        N.takeString =<< N.aether_hs_embed_sanitize_document h cHtml cBase

-- | Sanitize with a throwaway handle. Convenient for a single call; wasteful
-- in a loop, because it builds and tears down the whole default policy each
-- time.
sanitizeOnce :: B.ByteString -> IO B.ByteString
sanitizeOnce html = withSanitizer (`sanitize` html)

-- | 'sanitizeDocument' with a throwaway handle.
sanitizeDocumentOnce :: B.ByteString -> IO B.ByteString
sanitizeDocumentOnce html = withSanitizer (`sanitizeDocument` html)

-- ---------------------------------------------------------------------------
-- Flags
-- ---------------------------------------------------------------------------

-- | Keep the children of a removed element instead of dropping the subtree.
setKeepChildNodes :: Sanitizer -> Bool -> IO ()
setKeepChildNodes s on =
  withHandle s $ \h -> N.aether_hs_embed_set_keep_child_nodes h (boolToCInt on)

getKeepChildNodes :: Sanitizer -> IO Bool
getKeepChildNodes s =
  withHandle s $ \h -> cIntToBool <$> N.aether_hs_embed_get_keep_child_nodes h

-- | Let @data-*@ attributes through without listing each one.
setAllowDataAttributes :: Sanitizer -> Bool -> IO ()
setAllowDataAttributes s on =
  withHandle s $ \h -> N.aether_hs_embed_set_allow_data_attributes h (boolToCInt on)

getAllowDataAttributes :: Sanitizer -> IO Bool
getAllowDataAttributes s =
  withHandle s $ \h -> cIntToBool <$> N.aether_hs_embed_get_allow_data_attributes h

-- ---------------------------------------------------------------------------
-- Policy lists
-- ---------------------------------------------------------------------------

-- | Add an item to one of the six policy lists.
--
-- @
-- allow s Tags \"my-widget\"
-- @
allow :: Sanitizer -> N.Which -> B.ByteString -> IO Bool
allow s w item =
  withHandle s $ \h ->
    N.withUtf8 item $ \c -> cIntToBool <$> N.aether_hs_embed_allow h (N.whichCInt w) c

-- | 'allow' several items.
allowMany :: Sanitizer -> N.Which -> [B.ByteString] -> IO ()
allowMany s w = mapM_ (allow s w)

-- | Remove an item from a policy list — the deny direction (e.g. drop @a@
-- from the allowed tags).
disallow :: Sanitizer -> N.Which -> B.ByteString -> IO Bool
disallow s w item =
  withHandle s $ \h ->
    N.withUtf8 item $ \c -> cIntToBool <$> N.aether_hs_embed_disallow h (N.whichCInt w) c

-- | Is the item currently in the list?
isAllowed :: Sanitizer -> N.Which -> B.ByteString -> IO Bool
isAllowed s w item =
  withHandle s $ \h ->
    N.withUtf8 item $ \c -> cIntToBool <$> N.aether_hs_embed_is_allowed h (N.whichCInt w) c

-- | Empty a policy list — the \"start from nothing\" move for a caller who
-- wants a strict allow-list rather than the permissive defaults.
clearList :: Sanitizer -> N.Which -> IO Bool
clearList s w =
  withHandle s $ \h -> cIntToBool <$> N.aether_hs_embed_clear h (N.whichCInt w)

-- | How many entries a policy list holds.
countList :: Sanitizer -> N.Which -> IO Int
countList s w =
  withHandle s $ \h -> fromIntegral <$> N.aether_hs_embed_count h (N.whichCInt w)

-- | The item at an index, or @\"\"@ when out of range.
itemAt :: Sanitizer -> N.Which -> Int -> IO B.ByteString
itemAt s w i =
  withHandle s $ \h ->
    N.takeString =<< N.aether_hs_embed_item_at h (N.whichCInt w) (fromIntegral i)

-- | Every entry, in the engine's own order.
--
-- That order is unspecified but stable between mutations, so this yields each
-- item exactly once. Note the engine snapshots the whole set per @item_at@
-- call, making this O(n^2) — fine for policy lists of a few hundred entries
-- read at configuration time, which is what they are.
items :: Sanitizer -> N.Which -> IO [B.ByteString]
items s w = do
  n <- countList s w
  forM [0 .. n - 1] (itemAt s w)

-- | 'items', sorted. Use this when you want determinism.
sortedItems :: Sanitizer -> N.Which -> IO [B.ByteString]
sortedItems s w = sort <$> items s w

-- ---------------------------------------------------------------------------
-- Callbacks
-- ---------------------------------------------------------------------------

-- $callbacks
--
-- All seven hooks are supported. Passing 'Nothing' clears a hook.
--
-- For the @Removing*@ family, __returning 'True' CANCELS the removal__ — i.e.
-- keeps the node, attribute or CSS property:
--
-- @
-- onRemovingTag s $ Just $ \\node _reason -> (== \"keep-me\") \<$\> nodeName node
-- @
--
-- 'onFilterUrl' returns the URL to use; return the @resolved@ argument
-- unchanged for \"no rewrite\", or @\"\"@ to drop the attribute.
--
-- The 'Node' and 'Attribute' values a callback receives wrap __borrowed__
-- pointers, valid only for the duration of that callback. The DOM is freed
-- when the sanitize call returns, so do not retain one — read what you need
-- into a 'B.ByteString' inside the callback.
--
-- A hook runs on whatever OS thread the engine is calling from, inside a
-- @safe@ foreign call, so ordinary 'IO' is fine. An exception escaping a hook
-- would unwind through C, which is undefined behaviour, so each wrapper below
-- is written to be total; keep your own hook bodies exception-free.

-- | Register 'Nothing' to clear, or 'Just' a handler. Shared plumbing: build
-- the stub, retain it, hand the engine the raw pointer.
--
-- We pass 'nullPtr' as @user_data@ throughout. The ABI hands it back as the
-- callback's first argument so a binding can find its handler; a Haskell
-- closure already carries everything it needs, so the slot has no job here. We
-- still declare the parameter in every callback type, because the engine's
-- trampolines pass it unconditionally — a wrapper of the wrong arity would
-- shift every following argument.
registerHook
  :: Sanitizer
  -> (Ptr () -> Ptr () -> Ptr () -> IO ())   -- ^ the @on_*@ registrar
  -> (cb -> IO (FunPtr cb))                  -- ^ the matching @wrapper@ factory
  -> Maybe cb
  -> IO ()
registerHook s register mkStub mcb = withHandle s $ \h ->
  case mcb of
    Nothing -> register h nullPtr nullPtr
    Just cb -> do
      fp <- mkStub cb
      retainStub s fp
      register h (castFunPtrToPtr fp) nullPtr

-- | @on_removing_tag@ — return 'True' to keep a tag the engine would remove.
onRemovingTag :: Sanitizer -> Maybe (Node -> N.Reason -> IO Bool) -> IO ()
onRemovingTag s mcb =
  registerHook s N.aether_hs_embed_on_removing_tag N.mkCbRemovingTag (fmap wrap mcb)
  where
    wrap f = \_ud node reason -> boolToCInt <$> f (Node node) (N.reasonFromCInt reason)

-- | @on_removing_attribute@ — return 'True' to keep the attribute.
onRemovingAttribute
  :: Sanitizer
  -> Maybe (Node -> Attribute -> N.Reason -> IO Bool)
  -> IO ()
onRemovingAttribute s mcb =
  registerHook s N.aether_hs_embed_on_removing_attribute N.mkCbRemovingAttribute (fmap wrap mcb)
  where
    wrap f = \_ud elemP attrP reason ->
      boolToCInt <$> f (Node elemP) (Attribute attrP) (N.reasonFromCInt reason)

-- | @on_removing_style@ — the four-argument hook (element, property name,
-- property value, reason). Return 'True' to keep the CSS property.
--
-- The name and value are borrowed @const char*@; they are copied into
-- 'B.ByteString's before your handler sees them.
onRemovingStyle
  :: Sanitizer
  -> Maybe (Node -> B.ByteString -> B.ByteString -> N.Reason -> IO Bool)
  -> IO ()
onRemovingStyle s mcb =
  registerHook s N.aether_hs_embed_on_removing_style N.mkCbRemovingStyle (fmap wrap mcb)
  where
    wrap f = \_ud elemP cName cValue reason -> do
      name <- N.peekBorrowed cName
      value <- N.peekBorrowed cValue
      boolToCInt <$> f (Node elemP) name value (N.reasonFromCInt reason)

-- | @on_removing_comment@ — return 'True' to keep the comment.
onRemovingComment :: Sanitizer -> Maybe (Node -> IO Bool) -> IO ()
onRemovingComment s mcb =
  registerHook s N.aether_hs_embed_on_removing_comment N.mkCbRemovingComment (fmap wrap mcb)
  where
    wrap f = \_ud node -> boolToCInt <$> f (Node node)

-- | @on_post_process_node@ — called for each node after filtering.
onPostProcessNode :: Sanitizer -> Maybe (Node -> IO ()) -> IO ()
onPostProcessNode s mcb =
  registerHook s N.aether_hs_embed_on_post_process_node N.mkCbPostProcess (fmap wrap mcb)
  where
    wrap f = \_ud node -> f (Node node)

-- | @on_post_process_dom@ — called once with the document root.
onPostProcessDom :: Sanitizer -> Maybe (Node -> IO ()) -> IO ()
onPostProcessDom s mcb =
  registerHook s N.aether_hs_embed_on_post_process_dom N.mkCbPostProcess (fmap wrap mcb)
  where
    wrap f = \_ud node -> f (Node node)

-- | @on_filter_url@ — the string-returning hook, and the hardest shape in the
-- ABI.
--
-- Your handler is given the element, the raw attribute value, and the value
-- after the engine resolved it against the base URL. Return the URL to use:
-- the @resolved@ argument unchanged for no rewrite, @\"\"@ to drop the
-- attribute, or any replacement.
--
-- __Ownership:__ the engine takes the returned buffer and frees it with the C
-- library's @free@, so we allocate it with the engine's own @malloc@ via
-- 'HtmlSanitizer.Native.dupUtf8'. Do not free it yourself; a
-- GHC-allocated buffer here would be freed by the wrong allocator.
onFilterUrl
  :: Sanitizer
  -> Maybe (Node -> B.ByteString -> B.ByteString -> IO B.ByteString)
  -> IO ()
onFilterUrl s mcb =
  registerHook s N.aether_hs_embed_on_filter_url N.mkCbFilterUrl (fmap wrap mcb)
  where
    wrap f = \_ud elemP cRaw cResolved -> do
      raw <- N.peekBorrowed cRaw
      resolved <- N.peekBorrowed cResolved
      out <- f (Node elemP) raw resolved
      -- Always duplicate, even for "no rewrite". Returning `cResolved` itself
      -- is also legal (the engine's trampoline detects the identical pointer
      -- and short-circuits), but we have already copied the bytes into a
      -- ByteString, so we cannot tell "unchanged" from "rewritten to the same
      -- text" without comparing. Duplicating unconditionally is one malloc and
      -- removes the question.
      N.dupUtf8 out

-- | Clear all seven hooks in one go.
--
-- You rarely need this: 'close' frees the native handle, which tears down the
-- engine's hook boxes anyway. It is here for the case where one sanitizer is
-- reconfigured and reused, and it is what the conformance suite uses to prove
-- a cleared hook really stops firing.
--
-- Note this does not free the stubs — see 'Sanitizer' on why that is deferred
-- to 'close'.
clearHooks :: Sanitizer -> IO ()
clearHooks s = withHandle s $ \h ->
  mapM_
    (\register -> register h nullPtr nullPtr)
    [ N.aether_hs_embed_on_removing_tag
    , N.aether_hs_embed_on_removing_attribute
    , N.aether_hs_embed_on_removing_style
    , N.aether_hs_embed_on_removing_comment
    , N.aether_hs_embed_on_post_process_node
    , N.aether_hs_embed_on_post_process_dom
    , N.aether_hs_embed_on_filter_url
    ]

-- ---------------------------------------------------------------------------
-- DOM access
-- ---------------------------------------------------------------------------

-- | A __borrowed__ DOM node pointer, valid only inside the callback that was
-- handed it. The DOM is freed when the sanitize call returns.
newtype Node = Node (Ptr ())

-- | A __borrowed__ DOM attribute pointer. Same lifetime rule as 'Node'.
newtype Attribute = Attribute (Ptr ())

-- | @1=Document, 2=Element, 3=Text, 4=Comment@.
nodeKind :: Node -> IO N.NodeKind
nodeKind (Node p) = N.nodeKindFromCInt <$> N.aether_hs_embed_node_kind p

-- | Element tag name, lowercased by the parser; @\"\"@ for non-elements.
nodeName :: Node -> IO B.ByteString
nodeName (Node p) = N.takeString =<< N.aether_hs_embed_node_name p

-- | Text or comment content; @\"\"@ for elements and documents.
nodeValue :: Node -> IO B.ByteString
nodeValue (Node p) = N.takeString =<< N.aether_hs_embed_node_value p

nodeChildCount :: Node -> IO Int
nodeChildCount (Node p) = fromIntegral <$> N.aether_hs_embed_node_child_count p

-- | The child at an index, or 'Nothing' when out of range.
nodeChildAt :: Node -> Int -> IO (Maybe Node)
nodeChildAt (Node p) i = maybeNode <$> N.aether_hs_embed_node_child_at p (fromIntegral i)

-- | Every child, skipping any index the engine reports as null (it should not
-- happen for @0 .. count-1@, but the accessor is documented as NULL-safe and
-- dropping a hole beats a partial pattern match on it).
nodeChildren :: Node -> IO [Node]
nodeChildren n = do
  c <- nodeChildCount n
  catMaybes <$> forM [0 .. c - 1] (nodeChildAt n)

-- | The parent node, or 'Nothing' at the root.
nodeParent :: Node -> IO (Maybe Node)
nodeParent (Node p) = maybeNode <$> N.aether_hs_embed_node_parent p

nodeAttrCount :: Node -> IO Int
nodeAttrCount (Node p) = fromIntegral <$> N.aether_hs_embed_node_attr_count p

-- | The attribute at an index, or 'Nothing' when out of range.
nodeAttrAt :: Node -> Int -> IO (Maybe Attribute)
nodeAttrAt (Node p) i = maybeAttr <$> N.aether_hs_embed_node_attr_at p (fromIntegral i)

nodeAttributes :: Node -> IO [Attribute]
nodeAttributes n = do
  c <- nodeAttrCount n
  catMaybes <$> forM [0 .. c - 1] (nodeAttrAt n)

attrName :: Attribute -> IO B.ByteString
attrName (Attribute p) = N.takeString =<< N.aether_hs_embed_attr_name p

attrValue :: Attribute -> IO B.ByteString
attrValue (Attribute p) = N.takeString =<< N.aether_hs_embed_attr_value p

-- | Rewrite an attribute's value in place, e.g. to canonicalise a URL rather
-- than remove the attribute.
--
-- The engine copies the bytes, so the transient buffer this builds is safe.
setAttrValue :: Attribute -> B.ByteString -> IO ()
setAttrValue (Attribute p) v = N.withUtf8 v (N.aether_hs_embed_attr_set_value p)

maybeNode :: Ptr () -> Maybe Node
maybeNode p
  | p == nullPtr = Nothing
  | otherwise = Just (Node p)

maybeAttr :: Ptr () -> Maybe Attribute
maybeAttr p
  | p == nullPtr = Nothing
  | otherwise = Just (Attribute p)

-- ---------------------------------------------------------------------------
-- Introspection
-- ---------------------------------------------------------------------------

-- | The engine's ABI revision. Bumped when a symbol is added, never when one
-- changes meaning; check it to fail fast against an engine older than the
-- features you need.
abiVersion :: IO Int
abiVersion = fromIntegral <$> N.aether_hs_embed_abi_version

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

-- The ABI marshals every boolean as a C @int@: 0 is false, and for the
-- @removing_*@ hooks any NON-ZERO return cancels the removal. We emit 1 and
-- test /= 0, which is the safe pairing in both directions.
boolToCInt :: Bool -> CInt
boolToCInt True = 1
boolToCInt False = 0

cIntToBool :: CInt -> Bool
cIntToBool = (/= 0)
