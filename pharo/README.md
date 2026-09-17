# htmlsanitizer — Pharo (UnifiedFFI)

Cleans HTML of constructs that can lead to XSS.

This package is **marshalling only**. The sanitizer itself — HTML5 tokenizer,
DOM, CSS parser, URL resolver, allow-lists — is the pure-Aether sanitizer core in
`core/htmlsanitizer.ae`, shared by every language binding in this monorepo and
reached through the `aether_hs_embed_*` C ABI (`core/embed.ae`).

Unlike the Kotlin, Scala, Clojure and Groovy layers — which are thin wrappers
over the Java binding, because they share its runtime — **this is a real FFI**.
Pharo is not a JVM, so it binds the C ABI directly with UnifiedFFI.

## Requirements

* **Pharo 11 or newer** (developed and tested against Pharo 11). UnifiedFFI and
  SUnit are both in the base image, so the package has **no external
  dependencies**.
* The sanitizer core shared library, found at run time (see
  [Sanitizer core resolution](#sanitizer-core-resolution)).

## Loading it

From a checkout, with Metacello reading the Tonel sources straight from the
working tree:

```smalltalk
Metacello new
	baseline: 'HtmlSanitizer';
	repository: 'tonel:///path/to/html-sanitizer/pharo/src';
	load.
```

Or, if you just want the classes in a scratch image, file in the five
`.class.st` files under `src/HtmlSanitizer/`.

`aeb pharo/.tests.ae` does the load itself, into a **throwaway copy** of an
image — loading code mutates a Pharo image permanently, so the suite never
touches your own.

## Use

```smalltalk
| sanitizer |
sanitizer := HtmlSanitizer new.
[ sanitizer sanitize: '<div onclick=''alert(1)''>Hello</div>' ]
	ensure: [ sanitizer close ].
"-> '<div>Hello</div>'"
```

Better, let a block own the handle — this is the safe default, since a leaked
handle is native memory:

```smalltalk
HtmlSanitizer during: [ :s |
	s allow: 'my-widget' on: #tags.
	s keepChildNodes: true.
	s sanitize: '<img src="logo.png">' baseUrl: 'https://example.com' ].
```

or, for one fragment with the secure defaults:

```smalltalk
HtmlSanitizer sanitize: '<div onclick=''alert(1)''>Hello</div>'.
```

`close` is idempotent. The sanitizer is **not thread-safe** — the sanitizer core calls
hooks re-entrantly during `sanitize`.

## Allow-lists

Six live views on the sanitizer core, selected by symbol: `#tags`, `#attributes`,
`#cssProperties`, `#schemes`, `#classes`, `#uriAttributes`. Nothing is cached —
every query goes to the sanitizer core.

```smalltalk
s allow: 'my-widget' on: #tags.
s allowAll: #( 'b' 'i' ) on: #tags.
s disallow: 'script' on: #tags.
s isAllowed: 'http' on: #schemes.        "-> true"
s countOn: #schemes.                     "-> 2"
s allowedOn: #schemes.                   "-> a Set('http' 'https')"
s clear: #tags.
s replace: #( 'b' 'i' ) on: #tags.       "start from nothing"
```

A typo'd selector raises an error rather than silently widening the policy.

## Callbacks

Each `when*` takes a block. For the `removing*` family, **answering `true`
CANCELS the removal** — it keeps the thing. That inversion is the ABI's
("non-zero cancels"), and the `whenRemoving*` naming plus this note is the only
warning you get, so it is worth reading twice.

```smalltalk
s whenRemovingTag: [ :node :reason | node name = 'keep-me' ].
s whenRemovingAttribute: [ :elem :attr :reason | false ].
s whenRemovingStyle: [ :elem :name :value :reason | name = '-custom-thing' ].
s whenRemovingComment: [ :node | true ].

s whenPostProcessingNode: [ :node | ... ].
s whenPostProcessingDocument: [ :doc | ... ].

"Answer the URL to use; an EMPTY STRING drops the attribute.
 Answering nil means 'no rewrite'."
s whenFilteringUrl: [ :elem :raw :resolved |
	resolved copyReplaceAll: 'example.com' with: 'cdn.example.net' ].
```

Passing `nil` clears a hook. A block that falls off the end (answering `nil`)
counts as "do not keep", which is the safe direction for a sanitizer.

Removal reasons arrive as Symbols — `#notAllowedTag`, `#notAllowedAttribute`,
`#notAllowedStyle`, `#notAllowedUrlValue`, `#notAllowedValue`,
`#notAllowedCssClass`, `#classAttributeEmpty`, `#styleAttributeEmpty` — or
`#unknown` for a code this build does not know. The ABI's constants are
append-only, so `#unknown` means a newer sanitizer core, not an error.

## The DOM

`HsNode` and `HsAttribute` are **borrowed** views: the DOM is freed when
`sanitize` returns, so retaining one leaves a dangling pointer.

```smalltalk
node kind.                    "#document / #element / #text / #comment"
node name. node value.
node parent. node children. node attributes.
node attributeNamed: 'src'.   "or nil"
node walk.                    "depth-first Array, inclusive, built eagerly"
attr name. attr value. attr value: 'safe'.
```

When you want to keep something, **snapshot it**:

```smalltalk
s whenPostProcessingDocument: [ :doc | captured := doc asDictionary ].
"captured is plain immutable Pharo data — safe long after sanitize returned"
```

`asDictionary` exists precisely because "hold onto this node" is the reflex,
and the raw `HsNode` is the one thing you must not hold.

## Tests

```
aeb pharo/.tests.ae
```

or directly:

```
PHARO_DIR=~/.local/pharo \
HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so \
  ./run-tests.sh
```

The suite is SUnit (`HtmlSanitizerConformanceTest`), run headless. It mirrors
the 12 checks in `docs/conformance.md` and adds the remaining callback shapes,
plus checks specific to a real FFI binding: that `close` is idempotent (a
double free would crash, not raise), that `during:` closes even when the block
throws, that clearing a hook does not leave the sanitizer core calling a stale pointer,
and that `asDictionary` survives the callback.

Because this is the only *real* FFI in my family of five, those checks carry
their full weight here: a wrong callback width, a leaked caller-owned string, or
a garbage-collected callback shows up in exactly these tests.

### Two ABI traps worth knowing

Both of these were caught by the suite while writing it, and both are recorded
in the source:

* **Strings must be decoded as UTF-8 explicitly.** `readString` answers the raw
  bytes, so comparing it to a String fails even for pure ASCII, and non-ASCII
  gets mangled. `decodeUtf8:` uses `utf8StringFromCString`, which is what makes
  conformance check 04 (`café ☕`) round-trip.
* **Callback string parameters and returns are declared `void *`, not
  `char *`.** With `char *`, UnifiedFFI decodes parameters for us (the wrong
  layer), and — worse — tries to marshal the `ExternalAddress` returned from
  `whenFilteringUrl:` as though it were a Smalltalk String, dying with
  `Character doesNotUnderstand: #isExternalAddress` in the middle of a
  `sanitize`.

## Toolchain

`pharo/.tests.ae` **skips** rather than failing when no Pharo VM is present,
printing `pharo: skipped: pharo not installed`. It looks for `pharo` on `PATH`,
then `$PHARO_DIR` (default `~/.local/pharo`), and needs an `.image` alongside.
Nothing is downloaded: a test runner that installs a VM behind your back is a
worse failure mode than a clear skip.

```
mkdir -p ~/.local/pharo && cd ~/.local/pharo
curl -L https://get.pharo.org/64/110+vm | bash
```

## Sanitizer core resolution

`HtmlSanitizerLibrary` is the only class that knows where the sanitizer core lives.
Resolution order matches every other binding:

1. an explicit path — `HtmlSanitizerLibrary explicitPath: '/path/to/lib.so'`
   (set it *before* the first FFI call; UnifiedFFI caches the resolved handle)
2. `$HTMLSANITIZER_LIB`
3. `native/` beside the image
4. the OS loader's own search path

## Notes for maintainers

* **Every `char*` the ABI returns is caller-owned.** `takeString:` decodes and
  then frees it through `aether_hs_embed_free_string`, inside an `ensure:` so a
  malformed byte sequence cannot leak the buffer on its way out. Anything else
  leaks.
* `FFICallback` objects are held in the sanitizer's `callbacks` dictionary for
  its whole life. Letting one be garbage-collected while the sanitizer core can still
  call it crashes the VM. `close` frees the sanitizer core handle *first* — which
  releases the sanitizer core's callback boxes — so dropping the references immediately
  afterwards is safe.
* `whenFilteringUrl:`'s answer and `HsAttribute >> value:` both hand the sanitizer core
  a **libc-malloc'd** buffer it then owns and frees. `ExternalAddress
  allocate:` is malloc underneath, which is the matching allocator; neither is
  freed on this side.
* `HsAttribute >> value:` has that constraint for a second reason: the ABI
  stores the pointer directly into the DOM (`at.value = value`) rather than
  copying it, so the buffer must outlive the callback.
* The callback trampolines take `user_data` as their **first** argument and use
  C `int` widths. `core/embed.ae`'s doc comment writes `long`; the C in
  `core/_embed_support.c` is what actually runs, and it says `int`.
