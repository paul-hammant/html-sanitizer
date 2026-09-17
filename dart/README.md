# htmlsanitizer (Dart)

Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).

This package is a **thin `dart:ffi` binding** over the monorepo's one shared
native sanitizer core — `core/native/libhtmlsanitizer.so`, compiled from pure Aether.
It contains **no sanitizer logic**: every member marshals to an
`aether_hs_embed_*` call. One sanitizer core, one set of behaviours, N language
surfaces.

## Building

The sanitizer core is `dlopen`ed at runtime, so nothing needs to link against it —
just build it first:

```sh
cd core && ae build --emit=lib embed.ae --extra _embed_support.c \
    -o native/libhtmlsanitizer.so
cd ../dart && dart pub get
```

Library resolution, in order:

1. an explicit path — `HtmlSanitizer(nativeLibrary: '/path/to/lib.so')`
2. `$HTMLSANITIZER_LIB` (what the in-tree `.tests.ae` leaf sets)
3. `native/` next to the package, then `../core/native/` and `core/native/`
   (the in-tree monorepo layout)
4. the OS loader's own search path

`s.nativeLibraryPath` reports which one actually loaded.

## Usage

```dart
import 'package:htmlsanitizer/htmlsanitizer.dart';

final s = HtmlSanitizer();
try {
  final clean = s.sanitize('<div onclick="alert(1)">Hello <script>x</script></div>');
  // clean == '<div>Hello </div>'
} finally {
  s.close();
}
```

The second argument is the base URL used to resolve relative URLs; pass `''`
(the default) for no resolution.

`HtmlSanitizer.use` is the scoped form, and there are package-level one-shots
that create and release a handle around the call:

```dart
HtmlSanitizer.use((s) => s.sanitize(html));

sanitize('<div>a<script>b</script></div>');
sanitizeDocument(html, 'https://example.com/');
```

Using a closed sanitizer throws `StateError`. `close()` is idempotent.

### Policy lists

Six set-like views, each backed by the sanitizer core's own list — there is no Dart
mirror to fall out of sync:

```dart
s.allowedTags
s.allowedAttributes
s.allowedCssProperties
s.allowedSchemes
s.allowedClasses
s.uriAttributes
```

```dart
s.allowedTags.add('my-widget').add('my-other-widget');
s.allowedTags.addAll(['a', 'b']);
s.allowedTags.remove('div');
s.allowedSchemes.contains('http');    // true
s.allowedSchemes.length;              // 2
s.allowedSchemes.toSortedList();      // ['http', 'https']
s.allowedClasses.clear();
```

`toList()` enumerates in the sanitizer core's own (unspecified but stable) order;
`toSortedList()` is the deterministic version.

### Flags

```dart
s.keepChildNodes = true;       // keep children of a removed element
s.allowDataAttributes = true;  // let data-* through without listing each
```

### Callbacks

All seven hooks are supported. Each `on*` returns the `HtmlSanitizer`, so they
chain; passing `null` clears a hook.

For the `removing*` family, **returning `true` CANCELS the removal** (keeps
the node/attribute/property):

```dart
s.onRemovingTag((node, reason) => node.name == 'keep-me');
s.onRemovingAttribute((elem, attr, reason) => false);
s.onRemovingStyle((elem, name, value, reason) => name == '-custom-thing');
s.onRemovingComment((node) => true);
s.onPostProcessNode((node) { /* ... */ });
s.onPostProcessDom((doc) { /* ... */ });
s.onFilterUrl((elem, raw, resolved) => resolved);   // '' drops the attribute
```

`onFilterUrl` returns the URL to use. The string is copied into a `malloc`'d C
buffer the sanitizer core takes ownership of — you do not free it.

Dart forbids an `exceptionalReturn` on a pointer-returning native callback, so
a handler that **throws** hands the sanitizer core a null URL. Keep `onFilterUrl`
handlers total.

### Node and Attribute

Callbacks receive `Node` / `Attribute` values wrapping **borrowed** pointers,
valid only for the duration of that callback. The DOM is freed when
`sanitize` returns, so do not retain one.

```dart
node.kind;        // NodeKind.document | element | text | comment
node.name;        // lowercased tag name ('' for non-elements)
node.value;       // text/comment content
node.parent;      // Node?
node.children;    // List<Node>
node.attributes;  // List<Attribute>

attr.name;
attr.value;
attr.value = 'https://example.com/safe';   // rewrite in place
```

`attr.value = ...` is safe with a transient buffer: `aether_hs_embed_attr_set_value`
**copies** its argument core-side, so the binding frees the native string
immediately after the call.

## How the callback bridge works

`Pointer.fromFunction` only accepts a top-level or static function, which
cannot close over the user's handler. This binding therefore uses
**`NativeCallable.isolateLocal`** (Dart 3.1+), which wraps a *closure* in a
real C function pointer valid on the isolate that created it — exactly the
lifetime a synchronous `sanitize` call needs.

Two consequences shape the code:

- **Keepalive.** Every `NativeCallable` is stored on the `HtmlSanitizer`.
  Dropping the reference leaks the trampoline; closing it while the sanitizer core can
  still call it crashes the process. They are closed in `close()`, *after*
  `aether_hs_embed_free` has run — the only point at which the sanitizer core is
  guaranteed never to invoke a hook again.
- **`user_data` is unused.** The ABI passes an opaque `user_data` back as each
  callback's first argument so a binding can find the object that owns the
  hook. An isolate-local `NativeCallable` already closes over the handler, so
  Dart passes `nullptr` and ignores the round-tripped value. The C `int`
  widths still matter and are declared as `ffi.Int` throughout — declaring
  `ffi.Long` would give a 4-vs-8-byte mismatch on LP64 and garbage `reason`s.

## Memory

Every `char*` the sanitizer core returns is caller-owned. `Api.takeString` copies it
into a Dart string and frees it through `aether_hs_embed_free_string` in a
`finally`; every string result in this package goes through that one function.
Borrowed `const char*` **arguments** (the `name`/`value`/`raw`/`resolved`
callback parameters) go through `borrowString`, which does *not* free — the
sanitizer core owns those.

Strings handed *to* the sanitizer core are allocated with `calloc` and freed in a
`finally` around the call. The one exception is `onFilterUrl`'s return value,
allocated with `malloc` precisely because the sanitizer core frees it.

An `HtmlSanitizer` is **not** safe for concurrent use — the native handle
carries mutable policy and hook state, and `NativeCallable.isolateLocal`
trampolines are only valid on their creating isolate. Use one per isolate.

## Tests

The 12-check conformance suite (`docs/conformance.md`) lives in
`test/conformance_test.dart`, alongside extras covering the remaining callback
shapes. Checks 10 and 11 — the callback trampoline and the string-returning
`onFilterUrl` — are both implemented and passing; this binding skips nothing.

```sh
aeb dart/.tests.ae     # builds the sanitizer core, then runs dart test
# or, with the sanitizer core already built:
HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so dart test
```

`.tests.ae` skips (exit 0, with a clear `dart: SKIPPED` line) when no Dart SDK
is on `PATH`, or when `dart pub get` cannot resolve dependencies — rather than
failing the build DAG for a missing toolchain.
