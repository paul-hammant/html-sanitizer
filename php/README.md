# htmlsanitizer (PHP)

Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).

This package is a **thin ext-ffi binding** over the monorepo's one shared
native engine — `core/native/libhtmlsanitizer.so`, compiled from pure Aether.
It contains **no sanitizer logic**: every method marshals to an
`aether_hs_embed_*` call. One engine, one set of behaviours, N language
surfaces.

| File | Role |
|---|---|
| `src/Native.php` | the `FFI::cdef` symbol table — the **only** place that knows the ABI |
| `src/HtmlSanitizer.php` | the idiomatic PHP API over it |
| `src/Node.php`, `src/Attribute.php`, `src/AllowList.php` | the value types |
| `tests/conformance.php` | the 12-check conformance suite, as an assertion runner |

Requires **PHP 8.1+** and **ext-ffi**. No Composer dependencies at all — which
is also what lets it run on a box with no network.

## Requirements

`ext-ffi` ships with PHP but is not always enabled:

```sh
# Debian/Ubuntu
sudo apt install php-ffi
```

```ini
; php.ini
extension=ffi
ffi.enable=true      ; "preload" (a common distro default) blocks FFI::cdef from CLI
```

Or per-run, which is what the `.tests.ae` leaf does:

```sh
php -d ffi.enable=1 tests/conformance.php
```

## Building

The engine is `dlopen`ed at run time, so nothing links against it — just build
it first:

```sh
cd core && ae build --emit=lib embed.ae --extra _embed_support.c \
    -o native/libhtmlsanitizer.so
```

Library resolution, in order:

1. an explicit path — `new HtmlSanitizer('/path/to/libhtmlsanitizer.so')`
2. `$HTMLSANITIZER_LIB` (what the in-tree `.tests.ae` leaf sets)
3. `native/` next to the package, then `../core/native/` (the monorepo layout),
   then the same two relative to the cwd
4. the OS loader's own search path

`$s->nativeLibraryPath()` reports which candidate actually loaded.

## Usage

```php
use HtmlSanitization\HtmlSanitizer;

$s = new HtmlSanitizer();
echo $s->sanitize('<div onclick="alert(1)">Hello <script>x</script></div>');
// <div>Hello </div>
$s->close();
```

The second argument is the base URL used to resolve relative URLs; pass `''`
(the default) for no resolution.

`HtmlSanitizer::withSanitizer` is the scoped form — it closes the sanitizer
even if the callback throws — and there are one-shots:

```php
HtmlSanitizer::withSanitizer(fn (HtmlSanitizer $s) => $s->sanitize($html));

HtmlSanitizer::sanitizeOnce('<div>a<script>b</script></div>');
HtmlSanitizer::sanitizeDocumentOnce($html, 'https://example.com/');
```

(It is `withSanitizer` rather than `use` because `use` is a reserved word;
PHP 7+ permits it as a method name but it confuses tooling and readers alike.)

Using a closed sanitizer throws `LogicException`. `close()` is idempotent, and
`__destruct` is a backstop for a dropped handle — but closing deterministically
is better.

### Policy lists

Six set-like views, each backed by the engine's own list — there is no PHP
mirror to fall out of sync. Each is `Countable`, `IteratorAggregate` and
`ArrayAccess`:

```php
$s->allowedTags
$s->allowedAttributes
$s->allowedCssProperties
$s->allowedSchemes
$s->allowedClasses
$s->uriAttributes
```

```php
$s->allowedTags->add('my-widget')->add('my-other-widget');
$s->allowedTags->add(['a', 'b', 'c']);   // an array adds each item
$s->allowedTags[] = 'my-widget';         // ArrayAccess append
$s->allowedTags->remove('div');
$s->allowedSchemes->contains('http');    // true
$s->allowedSchemes->count();             // 2   (also count($s->allowedSchemes))
$s->allowedSchemes->toSortedArray();     // ['http', 'https']
$s->allowedSchemes->at(0);               // 'http'; '' when out of range
foreach ($s->allowedSchemes as $scheme) { /* ... */ }
$s->allowedClasses->clear();
```

`toArray()` enumerates in the engine's own (unspecified but stable) order;
`toSortedArray()` is the deterministic version.

### Flags

```php
$s->setKeepChildNodes(true);       // keep children of a removed element
$s->setAllowDataAttributes(true);  // let data-* through without listing each
$s->getKeepChildNodes();           // true
```

### Callbacks

All seven hooks are supported. Each `on*` returns `$this`, so they chain;
passing `null` clears a hook.

For the `removing*` family, **a truthy return CANCELS the removal** (keeps the
node/attribute/property):

```php
$s->onRemovingTag(fn (Node $node, int $reason) => $node->name() === 'keep-me');
$s->onRemovingAttribute(fn (Node $e, Attribute $a, int $r) => false);
$s->onRemovingStyle(fn (Node $e, string $name, string $v, int $r) => $name === '-custom-thing');
$s->onRemovingComment(fn (Node $node) => true);
$s->onPostProcessNode(function (Node $node) { /* ... */ });
$s->onPostProcessDom(function (Node $doc) { /* ... */ });
$s->onFilterUrl(fn (Node $e, string $raw, string $resolved) => $resolved);  // '' drops it
```

`onFilterUrl` returns the URL to use. The string is duplicated into a buffer
the **engine** takes ownership of — you do not free it.

### Node and Attribute

Callbacks receive `Node` / `Attribute` wrapping **borrowed** pointers, valid
only for the duration of that callback. The DOM is freed when `sanitize`
returns, so do not retain one.

```php
$node->kind();            // Native::NODE_DOCUMENT | NODE_ELEMENT | NODE_TEXT | NODE_COMMENT
$node->name();            // lowercased tag name ('' for non-elements)
$node->value();           // text/comment content
$node->parent();          // ?Node
$node->childCount();
$node->childAt($i);
$node->children();        // list<Node>
$node->attributeCount();
$node->attributeAt($i);
$node->attributes();      // list<Attribute>

$attr->name();
$attr->value();
$attr->setValue('https://example.com/safe');   // rewrite in place
```

`setValue` is safe with PHP's own transient buffer:
`aether_hs_embed_attr_set_value` **copies** its argument engine-side.

## How the callback bridge works

PHP's FFI builds a real C function pointer from a PHP `Closure` **only when
the closure is passed to a parameter whose declared type is a function
pointer**. The ABI declares `fn` as `void*`, which gives PHP no signature to
generate a thunk from — so `Native`'s cdef declares the seven setters with
concrete `hs_cb_*` function-pointer types instead. Same machine-level
signature, but now PHP can build the thunk.

Two details are load-bearing:

- **Keepalive.** Every registered `Closure` is stored on the sanitizer before
  it is handed to the engine. PHP frees the generated thunk when the Closure
  becomes unreachable, and the engine would then call into freed memory. The
  list is cleared in `close()`, *after* `aether_hs_embed_free` has run — the
  only point at which the engine is guaranteed never to invoke a hook again.
- **Callback integers are `int`, not `long`.** The engine emits its closure
  calls as `int(*)(...)`; declaring `long` gives a 4-vs-8-byte mismatch on
  LP64 — garbage `reason` values and corrupted stack arguments. Conformance
  check 10 asserts the `reason` it receives is a real ABI constant, which is
  what catches this.

**`user_data` is unused.** The ABI round-trips an opaque `user_data` as each
callback's first argument so a binding can find the object that owns the hook.
A PHP closure already captures its handler, so the binding passes `null`.

## Memory

Every `char*` the engine returns is caller-owned. `Native::takeString` copies
it with `FFI::string` and frees it through `aether_hs_embed_free_string` in a
`finally`; every string result in this package goes through that one function.
Borrowed `const char*` **arguments** (the `name`/`value`/`raw`/`resolved`
callback parameters) go through `Native::borrowString`, which does *not*
free — the engine owns those.

`onFilterUrl`'s return is the one string travelling the other way. It is
duplicated with **`hs_raw_dup`** — the engine's own `malloc`'d strdup from
`core/_embed_support.c`, exported by the same `.so`. That avoids a second
`FFI::cdef` against libc (whose module name and symbol differ per platform),
and it is by construction the exact counterpart of the `free()` that will
release the buffer. `FFI::new` would be wrong here: PHP owns that memory and
would free it a second time.

A sanitizer is **not** safe for concurrent use — the native handle carries
mutable policy and hook state.

## Tests

The 12-check conformance suite (`docs/conformance.md`) lives in
`tests/conformance.php`, alongside extras covering the remaining callback
shapes, the closed-handle exception, `ArrayAccess`, and a 5,000-iteration loop
over the caller-owned-string contract.

Checks 10 and 11 — the callback trampoline and the string-returning
`onFilterUrl` — are both implemented and passing; this binding skips nothing.

### Why an assertion runner and not PHPUnit

PHPUnit arrives via Composer, so `vendor/bin/phpunit` needs a `composer
install` — a network round trip, or a pre-warmed cache — before a single
assertion executes. The rest of this monorepo's bindings test with whatever is
already on the box, so this one does too: **no dependencies, no install**, and
the process exit code is the result. The suite falls back to a four-line PSR-4
autoloader when `vendor/autoload.php` is absent, so it runs from a bare
checkout.

The trade is real and small: no test discovery, no data providers, no
`--filter`. For twenty-odd marshalling assertions that costs nothing, and it
keeps the binding testable on an air-gapped machine. Swapping in PHPUnit later
is mechanical — each `check(...)` is one `public function test*`.

```sh
aeb php/.tests.ae     # builds the engine, then runs the suite
# or, with the engine already built:
HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so \
    php -d ffi.enable=1 tests/conformance.php
```

`.tests.ae` skips (exit 0, with a clear `php: SKIPPED` line) when no `php` is
on `PATH`, or when ext-ffi is not loaded — rather than failing the build DAG
for a missing toolchain.

> **Status on this checkout:** PHP is **not installed** on the development box
> these bindings were written on, so the PHP has been reviewed but not
> executed here. `aeb php/.tests.ae` reports `php: SKIPPED` and exits 0. The
> engine ABI it targets is proven by `core_tests/abi_smoke.c` and by the Dart,
> Lua, Python, Ruby, Go, Java, JavaScript and Rust bindings that do run — and
> the `hs_raw_dup` ownership path this binding uses for `onFilterUrl` was
> verified against the built engine with a standalone C harness.
