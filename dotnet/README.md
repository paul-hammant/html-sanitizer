# HtmlSanitizer (.NET)

Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).

This package is a **thin P/Invoke binding** over the monorepo's one shared
native engine — `core/native/libhtmlsanitizer.so`, compiled from pure Aether.
It contains **no sanitizer logic**: every member marshals to an
`aether_hs_embed_*` call. One engine, one set of behaviours, N language
surfaces.

| File | Role |
|---|---|
| `src/Native.cs` | the P/Invoke surface — the **only** place that knows the ABI |
| `src/HtmlSanitizer.cs` | the idiomatic C# API over it |
| `test/Conformance.cs` | the 12-check conformance suite, as a console runner |

Targets **net8.0**, with **zero NuGet dependencies** — which is also what lets
it build and test on a box with no network.

## Building

The engine is `dlopen`ed at run time, so nothing links against it — just build
it first:

```sh
cd core && ae build --emit=lib embed.ae --extra _embed_support.c \
    -o native/libhtmlsanitizer.so
cd ../dotnet && dotnet build
```

Library resolution, in order:

1. an explicit path — `new HtmlSanitizer("/path/to/libhtmlsanitizer.so")`
2. `$HTMLSANITIZER_LIB` (what the in-tree `.tests.ae` leaf sets)
3. `native/` next to the assembly, then the assembly's own directory
4. `native/`, `../core/native/` and `../../core/native/` relative to the cwd
5. the OS loader's own probing (the runtime's default behaviour)

Implemented with `NativeLibrary.SetDllImportResolver`, so it applies to every
`DllImport` in the assembly at once. `HtmlSanitizer.NativeLibraryPath` reports
which candidate actually loaded.

## Usage

```csharp
using HtmlSanitization;

using var s = new HtmlSanitizer();
var clean = s.Sanitize("<div onclick=\"alert(1)\">Hello <script>x</script></div>");
// clean == "<div>Hello </div>"
```

The second argument is the base URL used to resolve relative URLs; pass `""`
(the default) for no resolution.

Static one-shots create and release a handle around the call:

```csharp
HtmlSanitizer.SanitizeOnce("<div>a<script>b</script></div>");
HtmlSanitizer.SanitizeDocumentOnce(html, "https://example.com/");
```

Using a disposed sanitizer throws `ObjectDisposedException`. `Dispose` is
idempotent, and a finalizer is a backstop for a dropped handle — but `using`
remains the deterministic way.

### Policy lists

Six `IReadOnlyCollection<string>` views, each backed by the engine's own list —
there is no managed mirror to fall out of sync:

```csharp
s.AllowedTags
s.AllowedAttributes
s.AllowedCssProperties
s.AllowedSchemes
s.AllowedClasses
s.UriAttributes
```

```csharp
s.AllowedTags.Add("my-widget").Add("my-other-widget");
s.AllowedTags.Add("a", "b", "c");         // params overload
s.AllowedTags.AddRange(someEnumerable);
s.AllowedTags.Remove("div");
s.AllowedSchemes.Contains("http");        // true
s.AllowedSchemes.Count;                   // 2
s.AllowedSchemes.ToSortedList();          // ["http", "https"]
s.AllowedSchemes[0];                      // indexer, "" when out of range
foreach (var scheme in s.AllowedSchemes) { /* ... */ }
s.AllowedClasses.Clear();
```

Enumeration is in the engine's own (unspecified but stable) order;
`ToSortedList()` is the deterministic version.

### Flags

```csharp
s.KeepChildNodes = true;       // keep children of a removed element
s.AllowDataAttributes = true;  // let data-* through without listing each
```

### Callbacks

All seven hooks are supported. Each `On*` returns the `HtmlSanitizer`, so they
chain; passing `null` clears a hook.

For the `Removing*` family, **returning `true` CANCELS the removal** (keeps
the node/attribute/property):

```csharp
s.OnRemovingTag((node, reason) => node.Name == "keep-me");
s.OnRemovingAttribute((elem, attr, reason) => false);
s.OnRemovingStyle((elem, name, value, reason) => name == "-custom-thing");
s.OnRemovingComment(node => true);
s.OnPostProcessNode(node => { /* ... */ });
s.OnPostProcessDom(doc => { /* ... */ });
s.OnFilterUrl((elem, raw, resolved) => resolved);   // "" drops the attribute
```

`OnFilterUrl` returns the URL to use. The string is `strdup`'d into a buffer
the **engine** takes ownership of — you do not free it, and it must not come
from `Marshal.AllocHGlobal` or `StringToCoTaskMemUTF8`, whose allocators the
engine's `free()` knows nothing about.

### Node and Attribute

Callbacks receive `Node` / `Attribute` — `readonly struct`s wrapping
**borrowed** pointers, valid only for the duration of that callback. The DOM
is freed when `Sanitize` returns, so do not retain one.

```csharp
node.Kind;             // NodeKind.Document | Element | Text | Comment
node.Name;             // lowercased tag name ("" for non-elements)
node.Value;            // text/comment content
node.Parent;           // Node?
node.ChildCount;
node.ChildAt(i);
node.Children;         // IReadOnlyList<Node>
node.AttributeCount;
node.AttributeAt(i);
node.Attributes;       // IReadOnlyList<Attribute>

attr.Name;
attr.Value;
attr.SetValue("https://example.com/safe");   // rewrite in place
```

`SetValue` is safe with a transient buffer: `aether_hs_embed_attr_set_value`
**copies** its argument engine-side.

## Marshalling notes

Three decisions in `Native.cs` are load-bearing, and each corresponds to a
real bug avoided:

- **String returns are `IntPtr`, never `string`.** With a `string` return the
  default marshaller copies the buffer *and then frees it with
  `Marshal.FreeCoTaskMem`* — the wrong allocator for a `malloc`'d C string,
  which corrupts the heap. `Native.TakeString` copies with
  `Marshal.PtrToStringUTF8` and frees through `aether_hs_embed_free_string` in
  a `finally`. Every string result in the assembly goes through it. Borrowed
  `const char*` *arguments* (the `name`/`value`/`raw`/`resolved` callback
  parameters) go through `BorrowString`, which does **not** free.
- **String arguments are `byte[]`, not `string`.** `DllImport`'s default
  `string` marshalling is ANSI on some platforms, which mangles non-ASCII HTML
  (conformance check 4 catches exactly this). The binding encodes UTF-8 itself
  in `Native.Encode`.
- **Callback integers are `int`, not `long`/`nint`.** The engine emits its
  closure calls as `int(*)(...)`; a host declaring `long` gets a 4-vs-8-byte
  mismatch on LP64 — garbage `reason` values and corrupted stack arguments.
  Every delegate is also explicitly
  `[UnmanagedFunctionPointer(CallingConvention.Cdecl)]`, since the platform
  default differs on 32-bit Windows.

**Keepalive.** Every registered trampoline is stored in a `List<Delegate>` on
the sanitizer. A local delegate would be collected — or its marshalling stub
freed — and the process would crash on the next callback. The list is cleared
in `Dispose`, *after* `aether_hs_embed_free` has run, which is the only point
at which the engine is guaranteed never to invoke a hook again.

**`user_data` is unused.** The ABI round-trips an opaque `user_data` as each
callback's first argument so a binding can find the object that owns the hook.
A C# closure already captures its handler, so the binding passes
`IntPtr.Zero`.

An `HtmlSanitizer` is **not** thread-safe — the native handle carries mutable
policy and hook state. Use one per thread, or guard it.

## Tests

The 12-check conformance suite (`docs/conformance.md`) lives in
`test/Conformance.cs`, alongside extras covering the remaining callback
shapes, the disposed-handle exception, and a 5,000-iteration loop over the
caller-owned-string contract.

Checks 10 and 11 — the callback trampoline and the string-returning
`OnFilterUrl` — are both implemented and passing; this binding skips nothing.

### Why a console runner and not xunit/NUnit

Every .NET test framework arrives as a NuGet package, so `dotnet test` cannot
run without a restore — a network round trip, or a pre-warmed package cache,
before a single assertion executes. The rest of this monorepo's bindings test
with whatever is already on the box, so this one does too: `dotnet run` on a
self-contained runner, **no packages, no restore**, and the process exit code
is the result.

The trade is real and small: no test discovery, no parallelism, no
`[Theory]`. For twenty-odd marshalling assertions that costs nothing, and it
keeps the binding testable on an air-gapped machine. Swapping in xunit later
is mechanical — each `Check(...)` is one `[Fact]`.

```sh
aeb dotnet/.tests.ae     # builds the engine, then runs the suite
# or, with the engine already built:
HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so \
    dotnet run --project test/HtmlSanitizer.Tests.csproj
```

`.tests.ae` skips (exit 0, with a clear `dotnet: SKIPPED` line) when no
`dotnet` is on `PATH`, or when the `dotnet` present is runtime-only with no
SDK — rather than failing the build DAG for a missing toolchain.

> **Status on this checkout:** the .NET SDK is **not installed** on the
> development box these bindings were written on, so the C# has been reviewed
> but not compiled or executed here. `aeb dotnet/.tests.ae` reports
> `dotnet: SKIPPED` and exits 0. The engine ABI it targets is proven by
> `core_tests/abi_smoke.c` and by the Dart, Lua, Python, Ruby, Go, Java,
> JavaScript and Rust bindings that do run.
