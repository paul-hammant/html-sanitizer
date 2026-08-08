# htmlsanitizer (Haskell)

Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).

This package is a **thin GHC-FFI binding** over the monorepo's one shared
native engine — `core/native/libhtmlsanitizer.so`, compiled from pure Aether.
It contains **no sanitizer logic**: every function marshals to an
`aether_hs_embed_*` call across the C ABI described in `core/embed.ae`. One
engine, one set of behaviours, N language surfaces.

> ### Honest status: this code has never been compiled
>
> It was written on a machine with **no GHC, cabal or stack installed**, and a
> GHC install is a multi-gigabyte download that was out of scope here. So:
> every FFI type, import, language extension and cross-module name was checked
> **by hand** against `core/embed.ae`, `core/_embed_support.c`,
> `core_tests/abi_smoke.c` and the canonical symbol table in
> `rust/src/native.rs` — but **no compiler has confirmed any of it**.
>
> `haskell/.tests.ae` therefore SKIPs, loudly and truthfully:
>
> ```
> haskell: SKIPPED — ghc not installed (no GHC toolchain on PATH)
> ```
>
> It does **not** report a pass it did not earn. The first person to run this
> with a real GHC should expect to fix compile errors; the ABI-level design
> below is the part that was verified carefully, and the exported symbol names
> were checked against `nm -D` on the actual built `.so`.

## Layout

```
haskell/
    htmlsanitizer.cabal          build manifest
    src/HtmlSanitizer.hs         the public API
    src/HtmlSanitizer/Native.hs  the 1:1 C ABI symbol table
    test/Conformance.hs          the 12-check suite, a plain assertion runner
    native/                      where .tests.ae stages the engine .so
```

`src/HtmlSanitizer/Native.hs` mirrors `rust/src/native.rs`, which is the
canonical cross-binding reference: same symbols, same order, same constants.
The two can be diffed by eye.

## Building

Unlike the `dlopen`-based bindings (Python/ctypes, Ruby/Fiddle, PHP/FFI), this
one **LINKS** the engine, so the shared library must exist at *build* time as
well as run time. Build it first:

```sh
aeb core/.build.ae
# or, directly:
cd core && ae build --emit=lib embed.ae --extra _embed_support.c \
    -o native/libhtmlsanitizer.so
```

The `.cabal` searches both `haskell/native` and `../core/native`, and bakes the
same two directories in as `rpath`:

```
extra-lib-dirs:  native, ../core/native
extra-libraries: htmlsanitizer
ld-options:      -Wl,-rpath,native -Wl,-rpath,../core/native
```

Then either:

```sh
cabal build
cabal test conformance
```

or, with no package manager at all — which is how `.tests.ae` drives it,
because the dependency set is `base` + `bytestring` and both ship inside GHC:

```sh
runghc -isrc -itest -Lnative -lhtmlsanitizer test/Conformance.hs
```

That second form is the point of keeping the dependencies tiny: the suite runs
on an air-gapped box with no `cabal update`, no network and no package store.

## Usage

```haskell
{-# LANGUAGE OverloadedStrings #-}
import qualified Data.ByteString.Char8 as C
import HtmlSanitizer

main :: IO ()
main = withSanitizer $ \s -> do
    clean <- sanitize s "<div onclick=\"alert(1)\">Hello <script>evil()</script></div>"
    C.putStrLn clean
    -- <div>Hello </div>
```

`sanitizeWithBase` takes a base URL for resolving relative URLs; `sanitize`
passes `""` for "do not resolve".

```haskell
sanitizeWithBase s "<img src=\"logo.png\">" "https://example.com"
-- <img src="https://example.com/logo.png">
```

There are one-shots for a single call, which create and release a handle around
it:

```haskell
sanitizeOnce         :: ByteString -> IO ByteString
sanitizeDocumentOnce :: ByteString -> IO ByteString
```

### Strings

Everything is `ByteString`, holding UTF-8 bytes. The engine speaks UTF-8, so
passing bytes straight through is lossless and keeps the dependency set to
`base` + `bytestring`. Working in `Text`? Encode at the boundary with
`Data.Text.Encoding.encodeUtf8`.

### Policy lists

Six lists, selected by a `Which` constructor rather than the ABI's raw integer:

```haskell
allow      s Tags    "my-widget"
allowMany  s Tags    ["one", "two"]
disallow   s Tags    "div"
isAllowed  s Schemes "http"      -- IO True
countList  s Schemes             -- IO 2
items      s Schemes             -- engine order (unspecified but stable)
sortedItems s Schemes            -- IO ["http","https"]
clearList  s Schemes             -- start from nothing
```

`Which` is `Tags | Attributes | CssProperties | Schemes | Classes |
UriAttributes`, mapping to the ABI selectors 0..5.

### Flags

```haskell
setKeepChildNodes      s True   -- keep children of a removed element
setAllowDataAttributes s True   -- let data-* through without listing each
```

### Callbacks

All seven hooks are supported. Pass `Just handler` to set one, `Nothing` to
clear it. For the `Removing*` family, **returning `True` CANCELS the removal**
(i.e. keeps the node, attribute or CSS property):

```haskell
onRemovingTag s $ Just $ \node _reason ->
    (== "keep-me") <$> nodeName node

onRemovingAttribute s $ Just $ \_elem attr _reason -> do
    _ <- attrName attr
    pure False                       -- False = proceed with the removal

onRemovingStyle s $ Just $ \_elem name _value _reason ->
    pure (name == "-custom-thing")   -- the four-argument hook

onRemovingComment s $ Just $ \_node -> pure True

onPostProcessNode s $ Just $ \node -> nodeKind node >>= print
onPostProcessDom  s $ Just $ \doc  -> nodeChildren doc >>= print . length

onFilterUrl s $ Just $ \_elem _raw resolved ->
    pure $ if resolved == "https://example.com/logo.png"
             then "https://cdn.example.net/logo.png"
             else resolved           -- "" drops the attribute
```

`clearHooks s` clears all seven at once; `close` does it implicitly.

### Node and Attribute

Callbacks receive `Node` / `Attribute` values wrapping **borrowed** pointers,
valid only for the duration of the callback. The DOM is freed when the sanitize
call returns, so do not retain one — read what you need into a `ByteString`
inside the callback.

```haskell
nodeKind       :: Node -> IO NodeKind   -- Document | Element | Text | Comment
nodeName       :: Node -> IO ByteString -- lowercased tag name ("" for non-elements)
nodeValue      :: Node -> IO ByteString -- text/comment content
nodeParent     :: Node -> IO (Maybe Node)
nodeChildren   :: Node -> IO [Node]
nodeAttributes :: Node -> IO [Attribute]

attrName     :: Attribute -> IO ByteString
attrValue    :: Attribute -> IO ByteString
setAttrValue :: Attribute -> ByteString -> IO ()   -- rewrite in place
```

`setAttrValue` is safe with a transient buffer: `aether_hs_embed_attr_set_value`
copies engine-side (`core/embed.ae` does `string.concat("", value)` precisely
so a host's buffer can die immediately after).

## The rules that matter

### 1. Every returned `char*` is caller-owned

Rule one of this ABI: every string it hands back must be freed with
`aether_hs_embed_free_string`. Leaking them is the single most common bug in a
binding, so **every** returned string in this package goes through exactly one
function:

```haskell
takeString :: CString -> IO ByteString   -- packCString, then free through the ABI
```

`B.packCString` *copies* up to the NUL, so the `ByteString` stays valid after
the free. (`unsafePackCString` would alias the buffer we are about to hand
back — a use-after-free.) Funnelling every result through one helper is what
makes the ownership auditable rather than a per-call-site hope.

Borrowed strings — the `const char*` arguments a callback receives — go through
`peekBorrowed` instead, which copies and does **not** free.

### 2. `FunPtr` lifetime — the classic Haskell FFI bug

A `FunPtr` produced by `foreign import ccall "wrapper"` is a heap-allocated
executable stub that pins the Haskell closure behind it. The garbage collector
does not know the engine is holding a pointer to it, and it is **not** released
when the Haskell value goes out of scope. So a binding must:

- **retain** every stub it registers, for as long as the engine could call it,
  and
- **free** each exactly once, with `freeHaskellFunPtr`.

Drop the `FunPtr` and you leak the stub. Free it while the engine still holds
it and the next callback jumps through reclaimed memory.

This package keeps a list of deferred `freeHaskellFunPtr` actions in an `IORef`
on the `Sanitizer` and runs them in `close`. Re-registering a hook does **not**
free the superseded stub immediately — that is deliberately conservative, and
costs a few dozen bytes per re-registration.

`close` frees in a specific order, which is also deliberate: **the native
handle first** (which tears down the engine's hook boxes, so nothing can call
back), and only then the stubs.

### 3. `safe` vs `unsafe` foreign imports — and why it is not a micro-optimisation

Almost every import in `Native.hs` is `unsafe`: cheap, non-reentrant C calls
where skipping the safe-call bookkeeping is most of the cost.

**`aether_hs_embed_sanitize` and `aether_hs_embed_sanitize_document` are
imported `safe`, and that is load-bearing.** The engine calls *back into
Haskell* from inside them, through the registered hooks. A callback re-entering
the RTS from an `unsafe` foreign call is undefined behaviour: the calling
capability was never released, so the returning Haskell code runs on a
capability another thread may already own. It manifests as a hang or heap
corruption — not a clean error — and **only once a hook is registered**, which
is exactly the kind of latent bug that ships. See the GHC users' guide,
"Foreign imports and multi-threading".

The DOM accessors stay `unsafe` even though they run *inside* a callback, i.e.
inside a `safe` call already in progress. That is correct and normal: `unsafe`
is a claim about whether *this* call can re-enter the RTS, and none of them
can — they read a struct field and return.

### 4. `on_filter_url` and the allocator

`onFilterUrl` is the hardest shape in the ABI: a callback that returns a string
the engine takes ownership of. The engine's trampoline does
`string_new(out); free(out)` — it frees our buffer with the **C library's**
`free`.

So the buffer must come from the matching `malloc`. This binding imports the
engine's own strdup for exactly that purpose:

```haskell
foreign import ccall unsafe "hs_raw_dup" hs_raw_dup :: CString -> IO CString
```

Note the name: `hs_raw_dup` is **not** prefixed `aether_`, because it is plain
C in `core/_embed_support.c` rather than an Aether export. A GHC-allocated
buffer freed by libc `free` is undefined behaviour, and where the RTS and the
engine link different C runtimes it is a hard crash.

### 5. Callback signatures: `user_data` first, and `CInt` not `CLong`

Every hook takes the opaque `user_data` as its **first** argument, and every
integer is a C `int` — `CInt`. A host declaring `CLong` gets a 4-vs-8-byte
mismatch on LP64: garbage `reason` values and corrupted stack arguments.

This binding registers `nullPtr` as `user_data` — a Haskell closure already
carries everything it needs, so the slot has no job here — but still *declares*
the parameter in every callback type, because the engine's trampolines pass it
unconditionally and a wrapper of the wrong arity would shift every following
argument.

## Lifetime and threading

A `Sanitizer` owns a native handle and a set of `FunPtr` stubs. Neither is
garbage-collected, so `close` is not optional. Prefer `withSanitizer`, which
closes on the way out even if the body throws:

```haskell
withSanitizer $ \s -> ...
```

`close` is idempotent, and every operation on a closed sanitizer throws
`SanitizerClosed` rather than dereferencing a freed pointer.

A `Sanitizer` is **not** safe for concurrent use — the native handle carries
mutable policy and hook state. Use one per thread, or guard it with an `MVar`.

## Conformance

The 12-check suite (`docs/conformance.md`) lives in `test/Conformance.hs`.

**All twelve are covered, including 10 and 11.** Haskell expresses native
callbacks directly via `foreign import ccall "wrapper"`, so unlike the BEAM
bindings this one skips nothing:

| # | Check | Where |
|---|---|---|
| 1 | script removed | `01 script removed` |
| 2 | onclick removed | `02 onclick removed` |
| 3 | empty string | `03 empty string` |
| 4 | UTF-8 round trip | `04 utf-8 round trip` |
| 5 | allow a custom tag | `05 allow custom tag` |
| 6 | disallow a tag | `06 disallow tag` |
| 7 | membership + count | `07 membership and count` |
| 8 | enumeration | `08 enumeration` |
| 9 | `keepChildNodes` | `09 keep child nodes` |
| 10 | `onRemovingTag` cancels a removal | `10 onRemovingTag cancels` |
| 11 | `onFilterUrl` rewrites a URL | `11 onFilterUrl rewrites` |
| 12 | two handles are independent | `12 handles are independent` |

Plus extras for the remaining callback shapes and the marshalling paths they
exercise: the four-argument `onRemovingStyle`, `onRemovingComment` cancelling,
`onRemovingAttribute` reading name and value, `onPostProcessNode` /
`onPostProcessDom`, node-tree navigation, `setAttrValue`, attribute
enumeration, clearing and re-registering a hook, `sanitizeDocument`,
`allowDataAttributes`, `clearList`, out-of-range `itemAt`, all six `Which`
selectors round-tripping, closed-handle rejection, and a 5000-iteration loop
that would surface a leaked or double-freed result string.

It is a plain assertion runner with its own exit code — no hspec, no tasty, no
Hackage round trip — for the same reason `php/tests/conformance.php` and the
.NET console runner are: the suite must run with whatever is already on the
box. Swapping in hspec later is mechanical; each `check` is one `it`.

```sh
aeb haskell/.tests.ae   # builds the engine, stages it, runs the suite (or SKIPs)
```
