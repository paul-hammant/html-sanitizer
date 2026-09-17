# htmlsanitizer (Nim)

Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).

This package is a **thin `importc` binding** over the monorepo's one shared
native sanitizer core — `core/native/libhtmlsanitizer.so`, compiled from pure Aether.
It contains **no sanitizer logic**: every proc marshals to an
`aether_hs_embed_*` call across the C ABI described in `core/embed.ae`. One
sanitizer core, one set of behaviours, N language surfaces.

## Building

Unlike the dlopen-based bindings (Python/ctypes, Ruby/Fiddle, PHP/FFI), this
binding **links** the sanitizer core, so the shared library must exist at *build* time
as well as run time. Build it first:

```sh
cd core && ae build --emit=lib embed.ae --extra _embed_support.c \
    -o native/libhtmlsanitizer.so
```

The `{.passL.}` in `src/htmlsanitizer.nim` searches both `nim/native` and
`../core/native`, and bakes the same two directories in as `rpath`, so an
in-tree build needs no further setup and no `LD_LIBRARY_PATH`:

```
-Lnim/native -Lcore/native -lhtmlsanitizer
-Wl,-rpath,nim/native -Wl,-rpath,core/native
```

The paths are derived from `currentSourcePath()`, so they are correct no
matter which directory you invoke the compiler from.

For a distributable build, copy the sanitizer core into `nim/native/` (which
`.tests.ae` does automatically) so the rpath resolves without the monorepo
layout around it.

## Usage

```nim
import htmlsanitizer

withSanitizer s:
  echo s.sanitize("""<div onclick="alert(1)">Hello <script>evil()</script></div>""")
  # => <div>Hello </div>
```

`withSanitizer` is the scoped form — the Nim equivalent of Python's
`with HtmlSanitizer()`. It closes the handle on the way out, including on an
exception. The explicit form is `newSanitizer()` / `close()`:

```nim
let s = newSanitizer()
defer: s.close()
```

The optional second argument to `sanitize` is the base URL used to resolve
relative URLs; omit it or pass `""` for no resolution.

```nim
s.sanitize("""<img src="logo.png">""", "https://example.com")
# => <img src="https://example.com/logo.png">
```

Package-level one-shots create and release a handle around the call — fine for
a one-off, wasteful in a loop:

```nim
echo sanitize("<div>a<script>b</script></div>")
echo sanitizeDocument(html, "https://example.com/")
```

### Policy lists

Six set-like views, each backed by the sanitizer core's own list:

```nim
s.allowedTags
s.allowedAttributes
s.allowedCssProperties
s.allowedSchemes
s.allowedClasses
s.uriAttributes
```

```nim
s.allowedTags.add "my-widget"
s.allowedTags.add ["one", "two"]        # bulk
s.allowedTags.excl "div"                # the deny direction
"http" in s.allowedSchemes              # true
s.allowedSchemes.len                    # 2
s.allowedSchemes.items()                # sanitizer core order
s.allowedSchemes.sorted()               # @["http", "https"]
s.allowedClasses.clear()                # start from nothing
```

`items()` enumerates in the sanitizer core's own order (unspecified, but stable
between mutations, so each item appears exactly once); `sorted()` is the
deterministic version.

Enumeration is O(n²) — the ABI snapshots the whole set per `item_at`. That is
a deliberate ABI trade (no iterator handles for every binding to
lifetime-manage), and these are configuration-time policy lists of at most a
few hundred entries, not a hot path.

### Flags

```nim
s.keepChildNodes = true        # keep children of a removed element
s.allowDataAttributes = true   # let data-* through without listing each
```

Both read back as `bool`.

### Callbacks

All seven hooks are supported. Each `on*` returns the `Sanitizer` so they
chain, and passing `nil` clears a hook.

For the `Removing*` family, **returning `true` CANCELS the removal** (keeps
the node/attribute/property). The inversion is the ABI's, not ours.

```nim
s.onRemovingTag(proc (node: Node, reason: Reason): bool =
  node.name == "keep-me")

s.onRemovingAttribute(proc (elem: Node, attr: Attribute, reason: Reason): bool =
  false)

s.onRemovingStyle(proc (elem: Node, name, value: string, reason: Reason): bool =
  name == "-custom-thing")

s.onRemovingComment(proc (node: Node): bool = true)

s.onPostProcessNode(proc (node: Node) = discard)
s.onPostProcessDom(proc (doc: Node) = discard)

s.onFilterUrl(proc (elem: Node, raw, resolved: string): string =
  resolved)          # "" drops the attribute
```

`onFilterUrl` returns the URL to use. Return `resolved` unchanged for "no
rewrite" — the binding recognises that and hands the original pointer straight
back, costing no allocation. Any other string is copied into a buffer the
sanitizer core takes ownership of; **you do not free it**.

### Node and Attribute

Callbacks receive `Node` / `Attribute` values wrapping **borrowed** pointers,
valid only for the duration of the callback. The DOM is freed when `sanitize`
returns, so do not retain one.

```nim
node.kind          # nkDocument | nkElement | nkText | nkComment
node.name          # lowercased tag name ("" for non-elements)
node.value         # text/comment content
node.parent        # Node (check .isNil at the root)
node.children      # seq[Node]
node.attributes    # seq[Attribute]

attr.name
attr.value
attr.value = "https://example.com/safe"   # rewrite in place
```

`attr.value =` is safe to call with a transient Nim string: the sanitizer core copies
the bytes rather than aliasing the host buffer.

## How the callback bridge works

The ABI hands each hook an opaque `user_data` as its **first** argument, and
that is what makes real callbacks possible from a language whose closures are
not C function pointers.

- The trampolines are top-level `{.cdecl.}` procs — real C function pointers.
  A Nim closure is a two-word `(proc, env)` pair and cannot be one.
- `user_data` is the `Sanitizer` `ref` itself, cast to `pointer`. Each
  trampoline casts it back to find the Nim-side handler to invoke.
- The handlers are ordinary Nim closures stored **on** that `Sanitizer`, so
  anything they capture stays reachable.

### The GC keepalive requirement

The sanitizer core holds that `user_data` pointer for as long as the hook is
registered, but it is invisible to Nim's GC — nothing on the Nim side
references the `Sanitizer` from the collector's point of view. If the last Nim
reference went out of scope, the object would be freed and the sanitizer core left
holding a dangling pointer.

So `newSanitizer` calls `GC_ref` on itself and `close` calls the matching
`GC_unref`. That both keeps the object alive and pins its address, which
matters for any GC that could otherwise move it. `close` frees the native
handle *before* it unpins, so the sanitizer core cannot call back into an object that
is about to go away.

**`close` deliberately does NOT clear the hooks first.** That looks like the
tidy, defensive thing to do and it is exactly wrong. `aether_hs_embed_free`
already disposes of a still-installed hook box correctly, but clearing a hook
by hand goes through `swap_hook` in `core/embed.ae`, whose replace path never
frees the outgoing box — so a clear-then-free leaks one 16-byte box *per hook*
while a plain free leaks none. Measured with valgrind over 200 create/register/
close cycles with three hooks: 16,000 bytes lost with the clear, 6,400 without
it (the remainder is the sanitizer core's own per-`sanitize` leak, which every binding
shares). See "Known issues" in the repo README.

Verified green under `--mm:orc`, `--mm:arc` and `--mm:refc`.

### The `int`-not-`long` trap

Nim's `int` is pointer-sized — on LP64 it is C `long`, not C `int`. The
sanitizer core's codegen emits its closure calls as `int(*)(...)`, so a host declaring
those parameters as Nim `int` gets a 4-vs-8-byte mismatch: garbage `reason`
values and, on some ABIs, a corrupted argument register.

Every callback parameter and every ABI proc in `src/htmlsanitizer.nim` uses
`cint` explicitly for this reason. Do not "simplify" one of them to `int`.

The `onRemovingStyle` hook is also the odd arity out — five parameters
counting `user_data`, where the tag and attribute hooks take three and four.
Getting that wrong is stack-argument corruption, not a compile error.

## Memory

Every `cstring` the sanitizer core returns is caller-owned. Exactly one proc —
`takeString` — is allowed to touch a returned pointer, and it always copies
into a Nim `string` and frees the original through
`aether_hs_embed_free_string`. There is no other call to `free_string` in the
binding and no returned pointer escapes `takeString`.

This matters more in Nim than it looks: assigning a `cstring` to a `string`
*copies*, it does not adopt, so a forgotten free is a silent leak rather than
a crash.

The one place ownership flows the other way is `onFilterUrl`, which must hand
the sanitizer core a malloc'd string it will later `free()`. That free comes from the
sanitizer core's libc, so the malloc must too — a Nim-allocated buffer would be
released by the wrong allocator. The binding calls the sanitizer core's own exported
`hs_raw_dup` rather than binding libc `malloc` separately.

Strings with an interior NUL are **refused**, not truncated. Silently
truncating `<div>\0<script>` is how a sanitizer binding turns into a bypass.

A `Sanitizer` is **not** safe for concurrent use — the native handle carries
mutable policy and hook state. Use one per thread, or serialise access.

`close` is idempotent, and a closed sanitizer raises `HtmlSanitizerError` on
any further use rather than dereferencing a freed handle.

## Conformance

The 12-check conformance suite (`docs/conformance.md`) lives in
`tests/tconformance.nim`, alongside extras for the remaining callback shapes.

**All 12 checks are covered. This binding skips nothing.** Checks 10 and 11 —
the callback trampoline with cancel semantics, and the string-returning
`onFilterUrl` — are the two a binding is most likely to get subtly wrong, and
both are implemented and passing here rather than waived.

The extras cover `onRemovingAttribute`, `onRemovingComment`, the four-argument
`onRemovingStyle`, both post-process hooks, node-tree navigation from inside a
callback, in-place attribute rewriting, hook clearing, `abiVersion`,
closed-handle rejection, interior-NUL refusal, `sanitizeDocument`, and all six
policy-list selectors.

```sh
aeb nim/.tests.ae     # builds the sanitizer core, stages it into nim/native, runs the suite
```

With the sanitizer core already built, the suite runs standalone — no nimble required:

```sh
nim c -r tests/tconformance.nim
nim c -r --mm:refc tests/tconformance.nim    # also green under refc
```

`nimble test` works too where nimble is installed; `htmlsanitizer.nimble` is
the package manifest either way.
