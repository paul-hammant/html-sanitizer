# htmlsanitizer — JavaScript / Node binding

Cleans HTML of constructs that can lead to XSS.

This package is **marshalling only**. The sanitizer itself — HTML5 tokenizer,
DOM, CSS parser, URL resolver, allow-lists — is the pure-Aether engine in
`core/htmlsanitizer.ae`, shared by every language binding in this monorepo and
reached through the `aether_hs_embed_*` C ABI (`core/embed.ae`).

## Install

```
npm install koffi
```

The binding loads `libhtmlsanitizer.so` at runtime via
[koffi](https://koffi.dev). Resolution order:

1. an explicit path — `new HtmlSanitizer({ nativeLib: '/path/to/lib.so' })`
2. `$HTMLSANITIZER_LIB`
3. `native/` bundled next to this package
4. the OS loader's own search path

## Use

```js
const { HtmlSanitizer } = require('htmlsanitizer');

const s = new HtmlSanitizer();
try {
  console.log(s.sanitize('<div onclick="alert(1)">Hello</div>'));
  // -> <div>Hello</div>

  s.allowedTags.add('my-widget');
  s.keepChildNodes = true;

  // Relative URLs resolve against a base.
  console.log(s.sanitize('<img src="logo.png">', 'https://example.com'));
  // -> <img src="https://example.com/logo.png">
} finally {
  s.close();
}
```

`close()` releases the native handle. JavaScript has no deterministic
destructor, so close explicitly in a long-lived process; a
`FinalizationRegistry` frees handles that are dropped without one, but GC
timing is not a resource-management strategy.

## Allow-lists

Six `Set`-like views — `allowedTags`, `allowedAttributes`,
`allowedCssProperties`, `allowedSchemes`, `allowedClasses`, `uriAttributes`:

```js
s.allowedTags.add('my-widget');       // allow
s.allowedTags.delete('script');       // deny
s.allowedTags.has('div');             // query
s.allowedTags.size;                   // count
[...s.allowedTags];                   // enumerate (also .toArray())
s.allowedTags.clear().update(['b', 'i']);   // start from nothing
```

## Callbacks

All seven engine hooks are wired. Each `on*` returns `this`, so they chain;
passing `null` clears a hook.

```js
// Returning true from a removing* handler CANCELS the removal.
s.onRemovingTag((node, reason) => node.name === 'keep-me');
s.onRemovingAttribute((elem, attr, reason) => false);
s.onRemovingStyle((elem, name, value, reason) => name === '-custom-thing');
s.onRemovingComment((node) => true);

s.onPostProcessNode((node) => { /* ... */ });
s.onPostProcessDom((doc) => { /* ... */ });

// Rewrite a URL; '' drops the attribute.
s.onFilterUrl((node, raw, resolved) => resolved.replace('example.com', 'cdn.example.net'));
```

The `Node` and `Attribute` objects handed to a callback are **borrowed** — the
DOM is freed when `sanitize()` returns, so do not retain them past the call.

`Node` exposes `kind` (1=Document, 2=Element, 3=Text, 4=Comment), `name`,
`value`, `parent`, `children`, `attributes`. `Attribute` exposes `name` and a
read/write `value`.

## Tests

```
node --test test/conformance.test.js
```

or, with the engine built for you:

```
aeb javascript/.tests.ae
```

The suite is the 12-check conformance contract in `docs/conformance.md`, plus
extras covering the remaining callback shapes. It uses `node:test` and
`node:assert`, so koffi is the only dependency that has to be installed.

## Notes for maintainers

* **Koffi 3 represents pointers as BigInt**, not opaque objects, and a null
  pointer is `null`/`0n`. Decode an owned `char *` with
  `koffi.decode.string(ptr)` — the Koffi 2 spelling `koffi.decode(ptr, 'char *')`
  crashes the process here.
* Every string-returning ABI call is declared `void *`, never `const char *`,
  so the pointer survives long enough to be freed with
  `aether_hs_embed_free_string`. Declaring it `const char *` would let koffi
  decode-and-forget it, leaking every result.
* Registered callbacks are kept in `_keepalive` and unregistered on `close()`.
  An unregistered trampoline that the engine later calls crashes the process.
* `onFilterUrl` must hand the engine a **malloc'd** string it then owns; the
  binding uses libc `strdup` for that.
