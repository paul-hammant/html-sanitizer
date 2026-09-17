{-# LANGUAGE ForeignFunctionInterface #-}

-- |
-- Module      : HtmlSanitizer.Native
-- Description : The 1:1 symbol table for the HtmlSanitizer C ABI.
--
-- This module is the ONLY place in the Haskell binding that knows about the C
-- ABI. It mirrors @rust\/src\/native.rs@, which is the canonical cross-binding
-- reference: every symbol the sanitizer core exports appears here once, with the exact
-- C signature, in the order @core\/embed.ae@ declares it. No sanitizer logic
-- lives here or anywhere else in this package — the sanitizer core is
-- @core\/htmlsanitizer.ae@, compiled to @libhtmlsanitizer.so@.
--
-- == Naming
--
-- @core\/embed.ae@ names its exports @hs_embed_\<name\>@; building with
-- @--emit=lib@ mangles them to __@aether_hs_embed_\<name\>@__. That mangled
-- name is what we link against.
--
-- The one exception is 'hs_raw_dup', a plain C helper from
-- @core\/_embed_support.c@ with no @aether_@ prefix. See its note below.
--
-- == The two ownership rules
--
-- 1. __Every @CString@ this ABI returns is caller-owned__ and must be handed
--    back to 'aether_hs_embed_free_string'. Leaking it is the single most
--    common bug in a binding, so this package routes every returned string
--    through exactly one helper, 'takeString'.
--
-- 2. __Node and attribute pointers handed to a callback are borrowed__ — valid
--    only for the duration of that callback, because the DOM is freed when
--    @sanitize@ returns. Never retain one.
--
-- == Callback ABI
--
-- Each hook receives the opaque @user_data@ registered alongside it as its
-- __first__ argument; the sanitizer core's C trampolines (@core\/_embed_support.c@)
-- supply it. Integer arguments are C @int@ — 'CInt' — __not__ @long@. A host
-- declaring the wrong width gets a 4-vs-8-byte mismatch on LP64: garbage
-- @reason@ values and corrupted stack arguments.
--
-- For the @removing_*@ family (tag, attribute, style, comment), a __non-zero
-- return CANCELS the removal__ — i.e. keeps the node. 'CbFilterUrl' returns a
-- malloc'd C string the sanitizer core takes ownership of, or the @resolved@ pointer
-- unchanged to mean \"no rewrite\".
--
-- == @safe@ vs @unsafe@ imports
--
-- Nearly everything here is imported @unsafe@: these are cheap, non-reentrant
-- C calls, and @unsafe@ skips the safe-call bookkeeping (saving\/restoring the
-- Haskell stack pointer, releasing the capability) that dominates the cost of
-- a one-instruction accessor.
--
-- 'aether_hs_embed_sanitize' and 'aether_hs_embed_sanitize_document' are the
-- deliberate exceptions: they are imported __@safe@__, because the sanitizer core
-- calls __back into Haskell__ from inside them via the registered hooks. A
-- callback re-entering the RTS from an @unsafe@ foreign call is undefined
-- behaviour — the calling capability was never released, so the returning
-- Haskell code runs on a capability that another thread may already own. It
-- manifests as a hang or a heap-corruption crash, not a clean error, and only
-- once a hook is registered — which is exactly the kind of latent bug that
-- ships. See the GHC users' guide, \"Foreign imports and multi-threading\".
module HtmlSanitizer.Native
  ( -- * Allow-list selectors (ABI constants — append only, never renumber)
    Which (..)
  , whichCInt
  , cTags
  , cAttributes
  , cCssProperties
  , cSchemes
  , cClasses
  , cUriAttributes

    -- * Removal reasons, as passed to the callbacks
  , Reason (..)
  , reasonFromCInt
  , reasonNotAllowedTag
  , reasonNotAllowedAttribute
  , reasonNotAllowedStyle
  , reasonNotAllowedUrlValue
  , reasonNotAllowedValue
  , reasonNotAllowedCssClass
  , reasonClassAttributeEmpty
  , reasonStyleAttributeEmpty

    -- * Node kinds
  , NodeKind (..)
  , nodeKindFromCInt
  , nodeDocument
  , nodeElement
  , nodeText
  , nodeComment

    -- * Callback types (each takes @user_data@ FIRST; ints are 'CInt')
  , CbRemovingTag
  , CbRemovingAttribute
  , CbRemovingStyle
  , CbRemovingComment
  , CbPostProcess
  , CbFilterUrl

    -- * @foreign import ccall \"wrapper\"@ factories
  , mkCbRemovingTag
  , mkCbRemovingAttribute
  , mkCbRemovingStyle
  , mkCbRemovingComment
  , mkCbPostProcess
  , mkCbFilterUrl

    -- * Lifecycle
  , aether_hs_embed_new
  , aether_hs_embed_free
  , aether_hs_embed_free_string

    -- * The main entry points (imported @safe@ — they re-enter Haskell)
  , aether_hs_embed_sanitize
  , aether_hs_embed_sanitize_document

    -- * Boolean flags
  , aether_hs_embed_set_keep_child_nodes
  , aether_hs_embed_get_keep_child_nodes
  , aether_hs_embed_set_allow_data_attributes
  , aether_hs_embed_get_allow_data_attributes

    -- * Allow-list mutation
  , aether_hs_embed_allow
  , aether_hs_embed_disallow
  , aether_hs_embed_is_allowed
  , aether_hs_embed_clear
  , aether_hs_embed_count
  , aether_hs_embed_item_at

    -- * Callback registration (null @fn@ clears the hook)
  , aether_hs_embed_on_removing_tag
  , aether_hs_embed_on_removing_attribute
  , aether_hs_embed_on_removing_style
  , aether_hs_embed_on_removing_comment
  , aether_hs_embed_on_post_process_node
  , aether_hs_embed_on_post_process_dom
  , aether_hs_embed_on_filter_url

    -- * DOM accessors (borrowed pointers, valid only inside a callback)
  , aether_hs_embed_node_kind
  , aether_hs_embed_node_name
  , aether_hs_embed_node_value
  , aether_hs_embed_node_child_count
  , aether_hs_embed_node_child_at
  , aether_hs_embed_node_parent
  , aether_hs_embed_node_attr_count
  , aether_hs_embed_node_attr_at
  , aether_hs_embed_attr_name
  , aether_hs_embed_attr_value
  , aether_hs_embed_attr_set_value

    -- * Version / introspection
  , aether_hs_embed_abi_version

    -- * The sanitizer core's own strdup, for @filter_url@'s return value
  , hs_raw_dup

    -- * String marshalling helpers
  , takeString
  , peekBorrowed
  , withUtf8
  , dupUtf8
  ) where

import qualified Data.ByteString as B
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..))
import Foreign.Ptr (FunPtr, Ptr, nullPtr)

-- ---------------------------------------------------------------------------
-- Allow-list selectors
-- ---------------------------------------------------------------------------

-- | Which of the sanitizer core's six policy lists a call operates on.
--
-- The underlying integers are ABI constants — append only, never renumber:
--
-- @
--   0 = allowed_tags            1 = allowed_attributes
--   2 = allowed_css_properties  3 = allowed_schemes
--   4 = allowed_classes         5 = uri_attributes
-- @
data Which
  = Tags
  | Attributes
  | CssProperties
  | Schemes
  | Classes
  | UriAttributes
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The ABI integer for a 'Which'. The 'Enum' instance would give the same
-- answer, but spelling it out keeps the mapping greppable and makes an
-- accidental reordering of the constructors a visible diff rather than a
-- silent policy swap.
whichCInt :: Which -> CInt
whichCInt Tags = 0
whichCInt Attributes = 1
whichCInt CssProperties = 2
whichCInt Schemes = 3
whichCInt Classes = 4
whichCInt UriAttributes = 5

cTags, cAttributes, cCssProperties, cSchemes, cClasses, cUriAttributes :: CInt
cTags = 0
cAttributes = 1
cCssProperties = 2
cSchemes = 3
cClasses = 4
cUriAttributes = 5

-- ---------------------------------------------------------------------------
-- Removal reasons
-- ---------------------------------------------------------------------------

-- | Why the sanitizer core is about to remove something, as handed to the
-- @removing_*@ callbacks.
data Reason
  = NotAllowedTag
  | NotAllowedAttribute
  | NotAllowedStyle
  | NotAllowedUrlValue
  | NotAllowedValue
  | NotAllowedCssClass
  | ClassAttributeEmpty
  | StyleAttributeEmpty
  | UnknownReason CInt
    -- ^ A reason this binding predates. The ABI is append-only, so a newer
    -- sanitizer core can introduce one; surfacing the raw value beats crashing or
    -- silently reporting the wrong reason.
  deriving (Eq, Show)

reasonFromCInt :: CInt -> Reason
reasonFromCInt 0 = NotAllowedTag
reasonFromCInt 1 = NotAllowedAttribute
reasonFromCInt 2 = NotAllowedStyle
reasonFromCInt 3 = NotAllowedUrlValue
reasonFromCInt 4 = NotAllowedValue
reasonFromCInt 5 = NotAllowedCssClass
reasonFromCInt 6 = ClassAttributeEmpty
reasonFromCInt 7 = StyleAttributeEmpty
reasonFromCInt n = UnknownReason n

-- The same values as raw 'CInt's, for a caller comparing against the wire
-- format rather than pattern-matching on 'Reason'.
reasonNotAllowedTag, reasonNotAllowedAttribute, reasonNotAllowedStyle :: CInt
reasonNotAllowedUrlValue, reasonNotAllowedValue, reasonNotAllowedCssClass :: CInt
reasonClassAttributeEmpty, reasonStyleAttributeEmpty :: CInt
reasonNotAllowedTag = 0
reasonNotAllowedAttribute = 1
reasonNotAllowedStyle = 2
reasonNotAllowedUrlValue = 3
reasonNotAllowedValue = 4
reasonNotAllowedCssClass = 5
reasonClassAttributeEmpty = 6
reasonStyleAttributeEmpty = 7

-- ---------------------------------------------------------------------------
-- Node kinds
-- ---------------------------------------------------------------------------

-- | A DOM node's type. @0@ is what the ABI returns for a null node, which we
-- map to 'UnknownKind' rather than inventing a constructor for it.
data NodeKind
  = Document
  | Element
  | Text
  | Comment
  | UnknownKind CInt
  deriving (Eq, Show)

nodeKindFromCInt :: CInt -> NodeKind
nodeKindFromCInt 1 = Document
nodeKindFromCInt 2 = Element
nodeKindFromCInt 3 = Text
nodeKindFromCInt 4 = Comment
nodeKindFromCInt n = UnknownKind n

nodeDocument, nodeElement, nodeText, nodeComment :: CInt
nodeDocument = 1
nodeElement = 2
nodeText = 3
nodeComment = 4

-- ---------------------------------------------------------------------------
-- Callback types
-- ---------------------------------------------------------------------------
--
-- Note each takes @user_data@ first, and every integer is 'CInt'.
--
-- This binding does not actually use the @user_data@ slot to find its handler
-- — a Haskell @FunPtr@ made by a @wrapper@ import already closes over
-- everything the callback needs. We still declare the parameter, because the
-- sanitizer core's trampolines pass it unconditionally and a wrapper of the wrong
-- arity would shift every subsequent argument. We register 'nullPtr' for it.

-- | @int f(void* ud, void* node, int reason)@ — non-zero cancels the removal.
type CbRemovingTag = Ptr () -> Ptr () -> CInt -> IO CInt

-- | @int f(void* ud, void* elem, void* attr, int reason)@ — non-zero cancels.
type CbRemovingAttribute = Ptr () -> Ptr () -> Ptr () -> CInt -> IO CInt

-- | @int f(void* ud, void* elem, const char* name, const char* value, int reason)@
-- — four arguments plus @ud@, unlike the tag\/attribute hooks. Non-zero cancels.
type CbRemovingStyle = Ptr () -> Ptr () -> CString -> CString -> CInt -> IO CInt

-- | @int f(void* ud, void* node)@ — non-zero cancels the removal.
type CbRemovingComment = Ptr () -> Ptr () -> IO CInt

-- | @void f(void* ud, void* node)@ — used for both post-process hooks.
type CbPostProcess = Ptr () -> Ptr () -> IO ()

-- | @char* f(void* ud, void* elem, const char* raw, const char* resolved)@
--
-- Returns a malloc'd C string the sanitizer core takes ownership of, or the @resolved@
-- pointer unchanged for \"no rewrite\".
type CbFilterUrl = Ptr () -> Ptr () -> CString -> CString -> IO CString

-- Wrapper imports. Each turns a Haskell closure into a real C function
-- pointer the sanitizer core can call.
--
-- LIFETIME, and this is the classic Haskell FFI bug: the 'FunPtr' a wrapper
-- returns is a heap-allocated stub that pins the closure. It is NOT tracked by
-- the garbage collector on the C side, and it is NOT freed when the FunPtr
-- value goes out of scope in Haskell — it leaks until 'freeHaskellFunPtr', and
-- calling it AFTER that free is a jump into reclaimed memory. So a binding
-- must (a) retain every FunPtr it registers for as long as the sanitizer core can call
-- it, and (b) free it exactly once, at close. "HtmlSanitizer" keeps them in an
-- 'Data.IORef.IORef' on the sanitizer and frees them in @close@.
foreign import ccall "wrapper"
  mkCbRemovingTag :: CbRemovingTag -> IO (FunPtr CbRemovingTag)

foreign import ccall "wrapper"
  mkCbRemovingAttribute :: CbRemovingAttribute -> IO (FunPtr CbRemovingAttribute)

foreign import ccall "wrapper"
  mkCbRemovingStyle :: CbRemovingStyle -> IO (FunPtr CbRemovingStyle)

foreign import ccall "wrapper"
  mkCbRemovingComment :: CbRemovingComment -> IO (FunPtr CbRemovingComment)

foreign import ccall "wrapper"
  mkCbPostProcess :: CbPostProcess -> IO (FunPtr CbPostProcess)

foreign import ccall "wrapper"
  mkCbFilterUrl :: CbFilterUrl -> IO (FunPtr CbFilterUrl)

-- ---------------------------------------------------------------------------
-- The symbol table. Order mirrors core/embed.ae so the two can be diffed by
-- eye, exactly as rust/src/native.rs does.
-- ---------------------------------------------------------------------------

-- ---- lifecycle ----

foreign import ccall unsafe "aether_hs_embed_new"
  aether_hs_embed_new :: IO (Ptr ())

foreign import ccall unsafe "aether_hs_embed_free"
  aether_hs_embed_free :: Ptr () -> IO ()

foreign import ccall unsafe "aether_hs_embed_free_string"
  aether_hs_embed_free_string :: CString -> IO ()

-- ---- the main entry points ----
--
-- SAFE, not unsafe: the sanitizer core invokes the registered hooks from inside these
-- calls, so they re-enter the Haskell RTS. See the module header.

foreign import ccall safe "aether_hs_embed_sanitize"
  aether_hs_embed_sanitize :: Ptr () -> CString -> CString -> IO CString

foreign import ccall safe "aether_hs_embed_sanitize_document"
  aether_hs_embed_sanitize_document :: Ptr () -> CString -> CString -> IO CString

-- ---- boolean flags ----

foreign import ccall unsafe "aether_hs_embed_set_keep_child_nodes"
  aether_hs_embed_set_keep_child_nodes :: Ptr () -> CInt -> IO ()

foreign import ccall unsafe "aether_hs_embed_get_keep_child_nodes"
  aether_hs_embed_get_keep_child_nodes :: Ptr () -> IO CInt

foreign import ccall unsafe "aether_hs_embed_set_allow_data_attributes"
  aether_hs_embed_set_allow_data_attributes :: Ptr () -> CInt -> IO ()

foreign import ccall unsafe "aether_hs_embed_get_allow_data_attributes"
  aether_hs_embed_get_allow_data_attributes :: Ptr () -> IO CInt

-- ---- allow-list mutation (the `which` selector is an ABI constant) ----

foreign import ccall unsafe "aether_hs_embed_allow"
  aether_hs_embed_allow :: Ptr () -> CInt -> CString -> IO CInt

foreign import ccall unsafe "aether_hs_embed_disallow"
  aether_hs_embed_disallow :: Ptr () -> CInt -> CString -> IO CInt

foreign import ccall unsafe "aether_hs_embed_is_allowed"
  aether_hs_embed_is_allowed :: Ptr () -> CInt -> CString -> IO CInt

foreign import ccall unsafe "aether_hs_embed_clear"
  aether_hs_embed_clear :: Ptr () -> CInt -> IO CInt

foreign import ccall unsafe "aether_hs_embed_count"
  aether_hs_embed_count :: Ptr () -> CInt -> IO CInt

foreign import ccall unsafe "aether_hs_embed_item_at"
  aether_hs_embed_item_at :: Ptr () -> CInt -> CInt -> IO CString

-- ---- callbacks (fn pointer + opaque user_data; null fn clears) ----
--
-- The registration functions take the hook as a bare @void*@. We keep the
-- Haskell type as @Ptr ()@ and 'Foreign.Ptr.castFunPtrToPtr' at the call site,
-- rather than declaring seven differently-typed registrars, because that is
-- what the C signature actually says: @void f(void* h, void* fn, void* ud)@.

foreign import ccall unsafe "aether_hs_embed_on_removing_tag"
  aether_hs_embed_on_removing_tag :: Ptr () -> Ptr () -> Ptr () -> IO ()

foreign import ccall unsafe "aether_hs_embed_on_removing_attribute"
  aether_hs_embed_on_removing_attribute :: Ptr () -> Ptr () -> Ptr () -> IO ()

foreign import ccall unsafe "aether_hs_embed_on_removing_style"
  aether_hs_embed_on_removing_style :: Ptr () -> Ptr () -> Ptr () -> IO ()

foreign import ccall unsafe "aether_hs_embed_on_removing_comment"
  aether_hs_embed_on_removing_comment :: Ptr () -> Ptr () -> Ptr () -> IO ()

foreign import ccall unsafe "aether_hs_embed_on_post_process_node"
  aether_hs_embed_on_post_process_node :: Ptr () -> Ptr () -> Ptr () -> IO ()

foreign import ccall unsafe "aether_hs_embed_on_post_process_dom"
  aether_hs_embed_on_post_process_dom :: Ptr () -> Ptr () -> Ptr () -> IO ()

foreign import ccall unsafe "aether_hs_embed_on_filter_url"
  aether_hs_embed_on_filter_url :: Ptr () -> Ptr () -> Ptr () -> IO ()

-- ---- DOM accessors (borrowed pointers, valid only inside a callback) ----
--
-- These run INSIDE a callback, i.e. inside a `safe` foreign call that is
-- already in progress. That is fine and is the normal arrangement: `unsafe` is
-- about whether THIS call can re-enter the RTS, and none of these can — they
-- read a struct field and return.

foreign import ccall unsafe "aether_hs_embed_node_kind"
  aether_hs_embed_node_kind :: Ptr () -> IO CInt

foreign import ccall unsafe "aether_hs_embed_node_name"
  aether_hs_embed_node_name :: Ptr () -> IO CString

foreign import ccall unsafe "aether_hs_embed_node_value"
  aether_hs_embed_node_value :: Ptr () -> IO CString

foreign import ccall unsafe "aether_hs_embed_node_child_count"
  aether_hs_embed_node_child_count :: Ptr () -> IO CInt

foreign import ccall unsafe "aether_hs_embed_node_child_at"
  aether_hs_embed_node_child_at :: Ptr () -> CInt -> IO (Ptr ())

foreign import ccall unsafe "aether_hs_embed_node_parent"
  aether_hs_embed_node_parent :: Ptr () -> IO (Ptr ())

foreign import ccall unsafe "aether_hs_embed_node_attr_count"
  aether_hs_embed_node_attr_count :: Ptr () -> IO CInt

foreign import ccall unsafe "aether_hs_embed_node_attr_at"
  aether_hs_embed_node_attr_at :: Ptr () -> CInt -> IO (Ptr ())

foreign import ccall unsafe "aether_hs_embed_attr_name"
  aether_hs_embed_attr_name :: Ptr () -> IO CString

foreign import ccall unsafe "aether_hs_embed_attr_value"
  aether_hs_embed_attr_value :: Ptr () -> IO CString

-- | Rewrite an attribute's value from inside a callback.
--
-- The sanitizer core COPIES the buffer (@core\/embed.ae@ does @string.concat(\"\", value)@
-- precisely so a host's transient buffer is safe), so passing a 'withUtf8'
-- pointer that dies at the end of the bracket is fine.
foreign import ccall unsafe "aether_hs_embed_attr_set_value"
  aether_hs_embed_attr_set_value :: Ptr () -> CString -> IO ()

-- ---- version / introspection ----

foreign import ccall unsafe "aether_hs_embed_abi_version"
  aether_hs_embed_abi_version :: IO CInt

-- ---- the sanitizer core's own strdup ----

-- | @char* hs_raw_dup(const char* s)@ — the sanitizer core's @strdup@, from
-- @core\/_embed_support.c@.
--
-- NOTE the name: this one is __not__ prefixed @aether_@, because it is plain C
-- rather than an Aether export.
--
-- We use it, rather than 'Foreign.C.String.newCString' or a @malloc@ of our
-- own, for exactly one purpose: producing @filter_url@'s return value. The
-- sanitizer core's @hs_tramp_filter_url@ does @string_new(out); free(out)@ — it frees
-- our buffer with the C library's @free@. Allocating it with the sanitizer core's own
-- @malloc@ guarantees the matching allocator. A GHC-allocated buffer freed by
-- libc @free@ is undefined behaviour, and on a platform where the RTS and the
-- sanitizer core link different C runtimes (Windows most obviously) it is a hard
-- crash.
--
-- The returned pointer is handed straight to the sanitizer core; we must NOT free it.
foreign import ccall unsafe "hs_raw_dup"
  hs_raw_dup :: CString -> IO CString

-- ---------------------------------------------------------------------------
-- String marshalling
-- ---------------------------------------------------------------------------

-- | Copy an ABI-returned string out and free it through the ABI.
--
-- __This is the only place a returned @CString@ is consumed.__ Rule 1 of the
-- ABI is that every @char*@ out of the sanitizer core is caller-owned; funnelling them
-- all through one function is what makes that auditable. A null pointer (which
-- the ABI does not currently produce, but which a failed @malloc@ inside
-- @hs_raw_dup@ would) yields @\"\"@ rather than a segfault.
--
-- The result is a 'B.ByteString' of the raw UTF-8 bytes. This binding does not
-- decode to 'String'\/'Data.Text.Text': the sanitizer core speaks UTF-8 bytes, so
-- handing bytes back is both lossless and dependency-free.
takeString :: CString -> IO B.ByteString
takeString p
  | p == nullPtr = pure B.empty
  | otherwise = do
      -- packCString COPIES up to the NUL, so the ByteString stays valid after
      -- the free below. (BU.unsafePackCString would alias the buffer we are
      -- about to hand back to the sanitizer core — a use-after-free.)
      bs <- B.packCString p
      aether_hs_embed_free_string p
      pure bs

-- | Read a __borrowed__ @const char*@ that a callback was handed. NOT owned by
-- us: the sanitizer core frees it (or it points into the DOM), so this only copies.
peekBorrowed :: CString -> IO B.ByteString
peekBorrowed p
  | p == nullPtr = pure B.empty
  | otherwise = B.packCString p

-- | Run an action with a NUL-terminated copy of a 'B.ByteString'.
--
-- @Data.ByteString.Unsafe.unsafeUseAsCString@ is unsuitable here: it hands over
-- the ByteString's own buffer, which is NOT guaranteed to be NUL-terminated (a
-- slice of a larger string is not). 'B.useAsCString' copies and appends the
-- NUL, which is what a @const char*@ parameter requires.
--
-- An interior NUL truncates on the C side. That is the same behaviour every
-- other binding in this monorepo settles on for a value that has already been
-- accepted as a byte string; a policy item or an HTML fragment containing a
-- NUL byte is malformed input, not something to raise on.
withUtf8 :: B.ByteString -> (CString -> IO a) -> IO a
withUtf8 = B.useAsCString

-- | Copy a 'B.ByteString' into a buffer allocated by the __engine's__ @malloc@,
-- for handing to @filter_url@. See 'hs_raw_dup' for why the allocator matters.
--
-- The sanitizer core takes ownership of the result; do not free it.
dupUtf8 :: B.ByteString -> IO CString
dupUtf8 bs = B.useAsCString bs hs_raw_dup
