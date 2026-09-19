# HtmlSanitizer — monorepo

Clean HTML documents and fragments of constructs that can lead to **cross-site
scripting (XSS)**, across many languages — **one sanitizer core, many thin bindings,
one build**.

The sanitizer core is a single pure-Aether module in [`core/`](core/)
(`core/htmlsanitizer.ae` plus the `core/embed.ae` C ABI), built once here as a
native shared library (`libhtmlsanitizer.so`). Each language binding is a thin
FFI wrapper over that one sanitizer core, so they cannot drift from each other —
identical sanitization across languages is a build-time guarantee, not a test
target.

It is a port of Michael Ganss's C#
[HtmlSanitizer](https://github.com/mganss/HtmlSanitizer) — see
[Upstream](#upstream-michael-gansss-htmlsanitizer).

```python
from htmlsanitizer import HtmlSanitizer

s = HtmlSanitizer()
s.sanitize('<div onclick="steal()">hi <script>alert(1)</script></div>')
# '<div>hi </div>'
```

## Why one sanitizer core

An HTML sanitizer is a security boundary. The usual polyglot approach —
reimplement it per language — means every language gets its own subtly
different parser, and therefore its own subtly different set of XSS holes. A
bypass found in one implementation has to be re-found, re-reported and
re-fixed in all the others.

Here there is exactly one tokenizer, one DOM, one CSS parser, one URL
resolver, and one set of allow-lists. Fix a bypass once and every binding has
the fix the moment it rebuilds.

## Upstream: Michael Ganss's HtmlSanitizer

This project exists because of
[**HtmlSanitizer**](https://github.com/mganss/HtmlSanitizer) by
[**Michael Ganss**](https://github.com/mganss) and its contributors — the
long-established C# library that this sanitizer core is a port of. Not a
reimplementation from a spec: the allow-lists, the CSS and URL filtering
rules, the callback surface and the removal semantics are all theirs.

We also run **their test suite**. `core_tests/test_ganss_parity.ae` carries
186 of upstream's cases, machine-translated from `Tests.cs`. Those vectors
encode a decade of real XSS bypass reports, and they are the most valuable
thing this repo borrows — considerably more so than the source. Where our
output differs from theirs we treat it as our bug to explain, and the current
score is published in [`docs/ganss-parity.md`](docs/ganss-parity.md) rather
than quietly rounded up.

HtmlSanitizer is MIT-licensed, and so is this. See
[Credits and licence](#credits-and-licence).

## Layout

```
html-sanitizer/
  core/          # the sanitizer core + C ABI; builds libhtmlsanitizer.so once
  core_tests/    # sanitizer core behaviour (Aether) + C ABI conformance (pure C)
  python/        # ctypes              ruby/       # Fiddle
  go/            # cgo                 rust/       # libloading
  java/          # FFM / Panama        javascript/ # koffi (Node)
  dotnet/        # P/Invoke            dart/       # dart:ffi
  php/           # ext-ffi             lua/        # C extension (5.4)
  haskell/       # foreign import      pharo/      # UnifiedFFI (Smalltalk)
  nim/           # importc (linked)    zig/        # extern C (linked)
  erlang/        # C NIF (canonical, shared across the BEAM)
  elixir/ gleam/ # share the Erlang NIF — no second .so
  kotlin/ scala/ clojure/ groovy/   # JVM family — thin layers over the Java classes
  wasm/          # browser/DOM — recompiles the sanitizer core to wasm32 (not a .so consumer)
  docs/          # conformance suite, ABI reference
```

## Bindings

| Language | FFI mechanism | Binding |
|---|---|---|
| Python | ctypes | [python/](python/README.md) |
| Ruby | Fiddle | [ruby/](ruby/README.md) |
| Go | cgo | [go/](go/README.md) |
| Rust | libloading | [rust/](rust/README.md) |
| Java | FFM / Panama (JDK 22+) | [java/](java/README.md) |
| JavaScript / TS | koffi (Node) | [javascript/](javascript/README.md) |
| .NET | P/Invoke | [dotnet/](dotnet/README.md) |
| Dart | dart:ffi (also Flutter) | [dart/](dart/README.md) |
| PHP | ext-ffi | [php/](php/README.md) |
| Lua | C extension (Lua 5.4) | [lua/](lua/README.md) |
| Haskell | foreign import ccall | [haskell/](haskell/README.md) |
| Nim | importc (linked) | [nim/](nim/README.md) |
| Zig | extern C (linked) | [zig/](zig/README.md) |
| Erlang | C NIF (canonical — shared across the BEAM) | [erlang/](erlang/README.md) |
| Elixir | shares the Erlang NIF | [elixir/](elixir/README.md) |
| Gleam | shares the Erlang NIF | [gleam/](gleam/README.md) |
| Pharo | UnifiedFFI (Smalltalk) | [pharo/](pharo/README.md) |
| Browser / DOM | WebAssembly (wasm32, ~62 KB) | [wasm/](wasm/README.md) |

**JVM family.** Kotlin, Scala, Clojure and Groovy reach the sanitizer core through the
**Java binding's classes** via seamless JVM interop — there is *no second
native FFI*. Each is a thin idiomatic layer with its own conformance suite.

| Language | Idiomatic layer | Binding |
|---|---|---|
| Kotlin | trailing-lambda DSL | [kotlin/](kotlin/README.md) |
| Scala | `withSanitizer` helpers | [scala/](scala/README.md) |
| Clojure | fns + `with-open` | [clojure/](clojure/README.md) |
| Groovy | `Closure` DSL | [groovy/](groovy/README.md) |

**Browser.** `wasm/` is the one target that does not load the `.so` — a browser
cannot `dlopen` one. It recompiles the *same* sanitizer core sources to wasm32, so
client-side sanitization is the same logic as the server's rather than a
JavaScript reimplementation with its own distinct set of holes:

```js
import { HtmlSanitizer } from './dist/htmlsanitizer.mjs';
const s = await HtmlSanitizer.create();
el.innerHTML = s.sanitize(untrustedHtml);
```

## Features

Inherited from the sanitizer core, so identical in every binding:

- **Lenient HTML5 tokenizer + DOM parser** — handles malformed and half-open
  markup, void tags, comments, CDATA, and raw-text modes for `<script>` /
  `<style>`.
- **CSS inline-style parser** — filters `style` attributes and custom
  properties, and normalises backslash hex-escape obfuscation
  (`\75\72\6c(...)` does not sneak a `url(` past the filter).
- **RFC-compliant URL resolver** — resolves relative, absolute and
  protocol-relative URLs against a `base_url`, and filters by scheme.
- **Extensive secure defaults** — allow-lists for tags, attributes, CSS
  properties, schemes and URI attributes, all mutable per instance.
- **Callbacks** — `on_removing_tag`, `on_removing_attribute`,
  `on_removing_style`, `on_removing_comment`, `on_post_process_node`,
  `on_post_process_dom` and `on_filter_url`. For the `removing_*` family,
  returning true from your handler *cancels* the removal.

## Build and test

The build runner is [**aeb**](https://github.com/aether-lang-dev/aeb); the
sanitizer core is compiled by [**Aether**](https://github.com/aether-lang-dev/aether).

### Getting the toolchain (`ae` + `aeb`)

**Prerequisites, kept separate:**

- **Installing `ae` + `aeb`** needs only `curl` — as of aeb v0.298 the toolchain
  installs binary-first, no compiler and no `make`.
- **Building the sanitizer core** (`core/` → `libhtmlsanitizer.so`) needs a **C
  compiler** (Aether compiles to C) plus `git`. Nothing else — the sanitizer core has no
  third-party C dependencies.

**Recommended — `./bootstrap.sh`.** It installs a pinned `ae` then `aeb` into
`~/.local` (no sudo; `PREFIX=` to override) using the pins in
[`ci/versions.env`](ci/versions.env), preflights the C compiler, then builds the
sanitizer core and every binding whose toolchain is present.

**Manual — one line.** aeb's `get.sh` ensures both tools (a pinned `ae` >=
`AE_PIN`, then a pinned `aeb`) into `~/.local` (no sudo; `PREFIX=` to override):

```bash
curl -fsSL https://raw.githubusercontent.com/aether-lang-dev/aeb/main/get.sh \
  | AE_PIN=0.696.0 AEB_REF=v0.319 sh
```

Prefer downloading to a file first if you want the fetch error surfaced and
install progress shown; a path-named invocation runs the same way:

```bash
curl -fsSL https://raw.githubusercontent.com/aether-lang-dev/aeb/main/get.sh -o get.sh
AE_PIN=0.696.0 AEB_REF=v0.319 sh get.sh
```

(A CI step can instead *source* `get.sh` as a function library — set
`AEBGET_SOURCE_ONLY=1` so sourcing only defines the functions — then call
`aeb_bootstrap`.)

The known-good pair is `ae v0.696.0` + `aeb v0.319` (see `ci/versions.env`).
The ae **floor is 0.677.0** — aeb needs aether's `@c_callback`
weak-emit codegen (first in 0.677) and the `fs.make_temp_file` runtime symbols
(0.670); install ae and its `libaether.a` as one matched set, as `get.sh` does.

### Running it

```sh
./bootstrap.sh            # toolchain (if missing) + sanitizer core + present bindings
aeb core/.build.ae        # build the sanitizer core .so
aeb core_tests/.tests.ae  # sanitizer core behaviour (12 C# cases, in Aether)
aeb core_tests/.abi.ae    # C ABI conformance (pure C, dlopen only)
aeb core_tests/.xss.ae    # XSS bypass-vector gate (47 evasion techniques)
aeb python/.tests.ae      # one binding
aeb .presubmit.ae         # everything
```

Each binding's `.tests.ae` deps `core/.build.ae`, so the sanitizer core builds first
and the binding is handed its path via `HTMLSANITIZER_LIB`. `aeb` exits non-zero
when a leaf fails (≥ v0.287), so its status gates CI directly; per-node logs are
in `target/.aeb/logs/<label>.log`.

A binding whose toolchain is not installed **skips loudly** (`<lang>:
SKIPPED — …`) rather than failing the DAG, so a partial toolchain set still
gives a meaningful run.

## Adding a language

There is no tutorial, and there shouldn't be — the existing bindings are the
spec. Pick the nearest one by FFI mechanism, copy its shape, bind the ABI in
[`docs/abi.md`](docs/abi.md), and mirror the twelve checks in
[`docs/conformance.md`](docs/conformance.md).

## Security testing

`core_tests/.xss.ae` runs 47 known XSS evasion techniques against the sanitizer core —
case variation, entity encoding (`&#106;avascript:`), CSS escape obfuscation,
scheme padding, malformed markup, dangerous elements. A failure there is a live
hole, so it is a separate, loudly-named gate rather than extra cases inside the
behavioural suite. Two real bugs were found and fixed this way:

- `sanitize("<<a>")` **hung forever** — a `<` that started no recognised
  construct left the tokenizer scanning zero bytes per iteration. A denial of
  service in a library whose whole job is untrusted input.
- `" javascript:alert(1)"` (one leading space) **bypassed the scheme
  allow-list** entirely. `get_scheme` saw the space, reported "no scheme", and
  the URL was treated as relative — while browsers strip leading whitespace and
  execute it. It now skips leading whitespace and C0 controls.

The suite now has **no known gaps** — every vector in it is blocked. CSS
`expression()` was the last one open; it is filtered as of the always-on CSS
value checks described below.

Two further bypasses were found by porting upstream's own test suite (see
[`docs/ganss-parity.md`](docs/ganss-parity.md)) and fixed:

- **An unparseable scheme was treated as a relative URL.** `get_scheme()`
  returns `""` for both `/page.html` (safe) and `` `javascript:alert(1)` ``
  (a backtick is not a valid scheme character, so parsing gives up). Both call
  sites read `""` as "relative, therefore safe", so the grave-accent payload
  kept its attribute verbatim. Now a colon before any `/?#` means the author
  wrote a *scheme*, and one we cannot identify is refused.
- **Numeric entities without a closing semicolon were not decoded.** Browsers
  read `&#x6a` as `j`; we required the `;`, so
  `<IMG SRC=&#x6a&#x61&#x76&#x61&#x73&#x63&#x72&#x69&#x70&#x74&#x3a;alert(1)>`
  never formed `javascript:` and the scheme check never fired.

## Known issues

- **Per-`sanitize()` memory growth (~0.2–0.3 kB/call).** The sanitizer core frees the
  DOM, but Aether's `heap.free` on a `ptr` cannot decrement the refcounted
  `string` fields nested in heap-boxed structs, so those are not reclaimed.
  It is core-side and affects every binding equally — measured identically
  from pure C and from the bindings. Long-lived processes sanitizing steadily
  will grow. (The separate per-*handle* leak, ~10 kB per `new()`, was fixed by
  releasing the default allow-list sequences in `populate_defaults`.)
- **~~Hook-replacement leak (16 bytes per replaced/cleared hook)~~ — fixed.**
  `swap_hook` freed only the callback box's `env` and dropped the two-word box
  itself, so replacing or clearing a hook leaked — which made defensively
  clearing hooks before `free` *worse* than leaving them installed.
  `core/_embed_support.c` now exposes `hs_embed_cb_free_box` for the
  replace/clear path, distinct from the teardown-path `hs_embed_cb_free_env`
  (where the sanitizer core's own `free()` releases the box). Verified from pure C via
  `dlopen`, 200 cycles per mode: 0 bytes lost across register-once,
  replace-3x, and register-then-clear.
- **`on_removing_css_class` is declared but never fired.** The sanitizer core
  populates and frees the hook slot but has no call site for it — a gap in the
  original C# port, not in the ABI. The ABI deliberately does not expose it
  rather than offer a hook that never runs.

## Credits and licence

**Michael Ganss and the HtmlSanitizer contributors.** Portions copyright (c)
2013-2016. [github.com/mganss/HtmlSanitizer](https://github.com/mganss/HtmlSanitizer),
MIT. Two distinct debts, both substantial:

- **The sanitizer core** — `core/htmlsanitizer.ae` is a port of their C# library. Its
  default allow-lists (tags, attributes, CSS properties, schemes, URI
  attributes), its CSS and URL filtering behaviour, and its callback surface
  are derived from that work.
- **The tests** — `core_tests/test_ganss_parity.ae` reproduces 186 of their
  test cases. A sanitizer is only as good as the bypasses it has been shown,
  and that corpus is theirs.

This project is MIT-licensed, as is upstream. See [LICENSE](LICENSE).
