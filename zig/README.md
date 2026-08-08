# htmlsanitizer (Zig)

Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).

This package is a **thin Zig binding** over the monorepo's one shared native
engine — `core/native/libhtmlsanitizer.so`, compiled from pure Aether. It
contains **no sanitizer logic**: every method marshals to an
`aether_hs_embed_*` call across the C ABI described in `core/embed.ae`. One
engine, one set of behaviours, N language surfaces.

Requires **Zig 0.13.0**.

## Building

Like Go's cgo binding (and unlike the dlopen-based Python/ctypes and
Ruby/Fiddle ones), this binding **links** the engine, so the shared library
must exist at *build* time as well as run time. Build it first:

```sh
cd core && ae build --emit=lib embed.ae --extra _embed_support.c \
    -o native/libhtmlsanitizer.so
```

Then:

```sh
zig build test        # the conformance suite
zig build example     # build and run the demo
```

`build.zig` looks for the engine in this order, first hit wins:

1. `-Dengine=<path>` — what `.tests.ae` passes, using the artifact path `aeb`
   published for `core/.build.ae`
2. `$HTMLSANITIZER_LIB` — the same env var every other binding honours
3. `zig/native/` — a staged local copy, for a distributable build
4. `../core/native/` — the in-tree monorepo layout

Either a directory **or** a full path to the `.so` is accepted for 1 and 2,
because half the repo's tooling hands out one and half the other.

Each candidate directory is added as **both** `-L` and `rpath`. The rpath is
not optional: without it the binary links cleanly and then dies inside the
dynamic loader, which is a far more confusing failure than a missing-library
link error.

### Using it from another project

```zig
// build.zig
const hs = b.dependency("htmlsanitizer", .{});
exe.root_module.addImport("htmlsanitizer", hs.module("htmlsanitizer"));

// A Zig module carries source, not link flags — so YOU must link the engine:
exe.linkLibC();
exe.addLibraryPath(.{ .cwd_relative = "/path/to/core/native" });
exe.addRPath(.{ .cwd_relative = "/path/to/core/native" });
exe.linkSystemLibrary("htmlsanitizer");
```

## Usage

```zig
const std = @import("std");
const hs = @import("htmlsanitizer");

const s = try hs.Sanitizer.init(allocator);
defer s.deinit();

const clean = try s.sanitize("<div onclick=\"alert(1)\">Hello <script>evil()</script></div>", "");
defer allocator.free(clean);
// clean == "<div>Hello </div>"
```

The second argument is the base URL used to resolve relative URLs; pass `""`
for no resolution.

```zig
const clean = try s.sanitize("<img src=\"logo.png\">", "https://example.com");
// <img src="https://example.com/logo.png">
```

`sanitizeDocument` is the full-document entry point (currently the same engine
path, kept distinct so the two-method surface does not drift).

A package-level one-shot creates and releases a handle around the call:

```zig
const clean = try hs.sanitize(allocator, "<div>a<script>b</script></div>", "");
defer allocator.free(clean);
```

### Policy lists

Six lists, selected by an enum rather than the ABI's bare integer:

`.tags`, `.attributes`, `.css_properties`, `.schemes`, `.classes`,
`.uri_attributes`.

```zig
_ = try s.allow(.tags, "my-widget");
_ = try s.disallow(.tags, "div");
_ = try s.isAllowed(.schemes, "http");     // true
_ = s.count(.schemes);                      // 2
_ = s.clear(.classes);                      // start from nothing

const list = try s.items(.schemes);         // caller owns the slice AND each string
defer s.freeItems(list);
```

`items` enumerates in the engine's own order — unspecified but stable between
mutations. Sort it yourself if you need determinism.

### Flags

```zig
s.setKeepChildNodes(true);       // keep children of a removed element
s.setAllowDataAttributes(true);  // let data-* through without listing each
```

### Callbacks

All seven hooks are supported. `setHooks` takes the whole set at once; a field
left null is *cleared* engine-side, so Zig state and engine state stay in exact
correspondence. `resetHooks()` removes everything.

For the `removing_*` family, **returning `true` CANCELS the removal** — it
keeps the node/attribute/property. That inverts the naive reading of the
name, and it is the single most common misreading of this ABI.

```zig
var ctx = MyState{};
s.setHooks(.{
    .ctx = &ctx,
    .removing_tag = struct {
        fn f(ctx_: ?*anyopaque, node: hs.Node, reason: hs.Reason) bool {
            const st: *MyState = @ptrCast(@alignCast(ctx_.?));
            _ = st; _ = reason;
            const name = node.name(alloc) catch return false;
            defer alloc.free(name);
            return std.mem.eql(u8, name, "keep-me");   // true == KEEP
        }
    }.f,
    .filter_url = struct {
        fn f(_: ?*anyopaque, _: hs.Node, raw: []const u8, resolved: []const u8) []const u8 {
            _ = raw;
            return resolved;   // unchanged == "no rewrite"; "" drops the attribute
        }
    }.f,
});
```

The remaining hooks are `removing_attribute`, `removing_style` (four arguments:
elem, name, value, reason), `removing_comment`, `post_process_node` and
`post_process_dom`.

Zig has no closures, so state travels through the explicit `ctx: ?*anyopaque`
— the same shape the C ABI itself uses. There is no allocation and no
trampoline table: a `callconv(.C)` function *is* a C function pointer.

`filter_url` returns a plain Zig slice. The binding copies it into an
engine-owned buffer for you — you neither allocate nor free the return value.
Returning the `resolved` slice unchanged takes a pointer-identity fast path
with no copy at all.

### Node and Attribute

Callbacks receive `Node` / `Attribute` values wrapping **borrowed** pointers,
valid only for the duration of the callback. The DOM is freed when `sanitize`
returns, so do not retain one — they have no `deinit` for exactly that reason.

```zig
node.kind()                  // .document | .element | .text | .comment
try node.name(allocator)     // lowercased tag name; caller frees
try node.value(allocator)    // text/comment content; caller frees
node.childCount()
node.childAt(i)              // ?Node
node.parent()                // ?Node
node.attrCount()
node.attrAt(i)               // ?Attribute

try attr.name(allocator)
try attr.value(allocator)
try attr.setValue(allocator, "https://example.com/safe")
```

`setValue` is safe with a transient buffer: `hs_embed_attr_set_value` copies
engine-side, so nothing aliases your stack after the call. That is a documented
ABI guarantee, and the suite tests it with a stack array that dies immediately.

## Memory and ownership

Three rules, all of them enforced rather than merely documented.

**1. Every `char*` the ABI returns is caller-owned.** It came from `hs_raw_dup`
(a plain `malloc`) and must go back through `aether_hs_embed_free_string`. The
binding routes *every* returned string through one helper, `takeString`, which
copies into your allocator and frees the C buffer in a `defer`. There is
exactly one `free_string` call site in the whole binding — grep for it.

Every Zig-side result is therefore yours to free with the allocator you passed
in. The conformance suite runs entirely on `std.testing.allocator`, which fails
the test on a leak, so rule 1 is checked by the tests rather than trusted.

**2. Callback integers are C `int`, not `long`.** The engine's codegen emits
its closure calls as `int (*)(...)`; a host declaring `c_long` gets a
4-vs-8-byte mismatch on LP64 — garbage `reason` values and corrupted stack
arguments after it. Zig will not warn you, because the ABI is whatever you
declare. The suite asserts on the *value* of `reason` in checks 10 and the
attribute/style extras, so this cannot regress silently.

**3. A registered callback must outlive the engine's ability to call it.**
`callconv(.C)` functions are static code, so the function half is free. The
`user_data` half is not: it is the address of the `Sanitizer`. That is why
`Sanitizer.init` returns a heap-allocated `*Sanitizer` rather than a value — a
by-value return would let you copy it to a new address, leaving the engine
calling into a dead stack frame. `deinit` clears every hook *before* freeing
the handle, so the engine never holds a pointer to freed memory even briefly.

### An engine-side leak this binding works around

While verifying the binding under valgrind, one leak turned out **not** to be
the binding's. `swap_hook` in `core/embed.ae` calls `hs_embed_cb_free_env(old)`,
which frees the outgoing box's `env` but deliberately not the box itself — the
comment in `core/_embed_support.c` says "the engine's `heap.free()` on the hook
slot does that". On the *replace* path nothing ever does. So every
re-registration or manual clearing of an already-registered hook leaks one
16-byte `HsClosure`.

It reproduces in pure C, dlopen plus the ABI, with no Zig involved:

```
register a hook once, then hs_embed_free   ->  0 bytes leaked
register, then re-register 3 more times    ->  3 x 16 bytes leaked
register, then CLEAR it, then hs_embed_free -> 16 bytes leaked
```

That last line is the counterintuitive one, and it changed this binding's
design. Clearing hooks before freeing the handle is the obvious defensive move,
and it is exactly wrong: `hs_embed_free` already unregisters and frees each
installed box correctly, so a tidy-looking clear-then-free leaks a box per hook
while simply freeing the handle leaks nothing. `deinit` therefore does **not**
clear hooks, with a comment saying why so nobody "fixes" it back.

The binding also declines to provoke the replace path. A slot's trampoline
pointer is a compile-time constant, so re-registering an already-registered
slot is a semantic no-op that only leaks. `setHooks` tracks which slots are
live engine-side and calls the ABI only on a real null↔set transition — so
repeated `setHooks` calls, the normal thing to do when reconfiguring between
documents, are leak-free. A test drives 25 set/reset cycles to keep it that way.

What remains unavoidable: a caller who genuinely clears a live hook
(`resetHooks`, or dropping one from the set) leaks 16 bytes per cleared slot.
That is bounded by the number of clears, not by document count or size, so it
does not accumulate in a sanitize loop. **Fixing it properly means freeing the
old box in `swap_hook` engine-side, which is outside this leaf's remit.**

Separately, valgrind shows engine-internal leaks from `hs_embed_sanitize`
itself (`aether_caps_malloc` under `string_substring` / `string_concat`, in
`htmlsanitizer_resolve_url` among others). Those are the engine's, are reached
identically from every binding, and are noted here only so a future reader does
not mistake them for a Zig marshalling bug.

One more: an interior NUL in an input string is an **error**
(`error.InteriorNul`), not a silent truncation. Zig slices carry NULs happily
and C strings do not; truncating would mean the engine sanitized less HTML than
you handed it, which is a security bug rather than a formatting one.

A `*Sanitizer` is **not** safe for concurrent use — the native handle carries
mutable policy and hook state. Use one per thread, or guard it.

## Conformance

The 12-check suite (`docs/conformance.md`) lives in `src/conformance.zig`,
pulled into `zig build test` by a `test` block at the bottom of `src/root.zig`.

**All 12 checks are covered; this binding skips nothing.** Checks 10 and 11 —
the callback trampoline with cancel semantics, and the string-returning
`filter_url` — are the two a binding is most likely to get subtly wrong, and
Zig expresses both natively: a `callconv(.C)` function plus a `*anyopaque`
context is precisely the shape the C ABI asks for, with no closure allocation,
no GC keepalive list and no marshalling layer in between.

Beyond the twelve, the suite covers the remaining callback shapes and the
Zig-specific hazards:

- `on_removing_attribute` reading both accessors, and asserting `reason == 1`
- `on_removing_comment` cancelling a removal
- `on_removing_style`, the four-argument shape (five C arguments with
  `user_data`) — where an off-by-one in the signature shows up as shifted
  values rather than a crash
- `on_post_process_node` and `on_post_process_dom`, plus DOM tree navigation
- `attr.setValue` from a stack buffer that dies on return
- hook replace-then-clear, so a stale trampoline cannot survive
- `filter_url`'s no-rewrite path, distinct from its rewrite path
- `sanitize_document`, `allow_data_attributes`, `clear`, and `item_at`
  out-of-range returning an owned `""` rather than null
- interior-NUL rejection
- 25 setHooks/resetHooks cycles, guarding the engine-leak workaround below
- a long input that overruns the stack-buffer cutoff, proving nothing
  truncates at 256 bytes

```sh
aeb zig/.tests.ae     # builds the engine, stages it, runs zig build test
# or, with the engine already built:
zig build test
zig build test --summary all    # see the count
```

30 tests, all passing.
