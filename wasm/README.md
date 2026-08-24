# htmlsanitizer — WebAssembly (browser / DOM)

The sanitizer engine compiled to **wasm32**, so untrusted HTML can be cleaned
in the browser before it ever reaches `innerHTML`.

```js
import { HtmlSanitizer } from './dist/htmlsanitizer.mjs';

const s = await HtmlSanitizer.create();
el.innerHTML = s.sanitize(untrustedHtml);      // or: s.setInnerHTML(el, html)
```

~62 KB of `.wasm` plus ~13 KB of JS glue via Emscripten — or an ~85 KB
single self-contained `.wasm` with **no glue at all** via `zig cc`. Both
backends are supported and tested; see [Two backends](#two-backends).

## Why not just use a JS sanitizer

Because this is the **same engine** as the Python, Java, Go, Rust, … bindings —
the same tokenizer, the same allow-lists, the same URL resolver, recompiled
rather than reimplemented. What your backend strips and what the browser
strips cannot drift apart, which is the failure mode a second implementation
guarantees: a bypass fixed server-side but still live in the client.

It also means fixes arrive everywhere at once. Both security bugs found while
building this repo — the `" javascript:"` scheme-padding bypass and the
`"<<a>"` tokenizer hang — were fixed once in `core/` and are covered here by
regression tests in `test/conformance.test.mjs`.

The trade-off is honest: a wasm module is a bigger download than a small JS
sanitizer, and it needs `await` before first use. If those matter more than
cross-language consistency, this is the wrong tool.

## Build (Emscripten)

Needs the Emscripten SDK (not on this box by default — it is a ~1 GB
download, which is why `wasm/.tests.ae` skips rather than fails without it):

```sh
git clone https://github.com/emscripten-core/emsdk
cd emsdk && ./emsdk install latest && ./emsdk activate latest
source ./emsdk_env.sh
```

Then:

```sh
./build.sh                 # emcc on PATH
EMSDK=/path/to/emsdk ./build.sh
```

Outputs `dist/htmlsanitizer.{js,wasm,mjs}`.

### What the build does differently

Two non-obvious things, both load-bearing:

1. **`aetherc --emit=csrc`, not plain `aetherc`.** Only that mode applies the
   `aether_` export mangling, so the symbols `wasm-ld` is told to `--export`
   actually exist. Plain codegen emits bare `hs_embed_new` and the link fails
   with *"symbol exported via --export not found"*.
2. **A minimal runtime source list, not `share/aether/MANIFEST`.** The full
   manifest pulls in `multicore_scheduler.c`, which fails a `Mailbox`
   8-byte-alignment `static_assert` on wasm32. `build.sh` mirrors the
   `RUNTIME_FILES` list from Aether's own `make ci-wasm`, plus what the
   sanitizer needs (strbuilder / bytes / mem / set / stringseq / alloc).

PCRE2 is stubbed out (`src/regex_stub.c`). The engine's only regex use is the
never-wired `disallow_css_property_value_regex` field, which is always null —
so stubbing keeps the whole PCRE2 port out of the bundle at no behavioural
cost. If that field is ever wired up, this stub has to go and PCRE2 must be
built as an emscripten port.

## Two backends

Either is sufficient; `wasm/.tests.ae` runs whichever is installed (both, if
both are) and asserts the *same* 22 conformance checks against each, so a
divergence is a build bug rather than a behavioural difference.

| | `build.sh` (Emscripten) | `build-zig.sh` (`zig cc`) |
|---|---|---|
| output | `htmlsanitizer.wasm` + `.js` glue | `htmlsanitizer-wasi.wasm`, **no glue** |
| size | ~62 KB + ~13 KB | ~85 KB |
| toolchain | emsdk (~1 GB) | one Zig tarball (~50 MB) |
| target | `wasm32-emscripten` | `wasm32-wasi` |
| driven by | emscripten runtime | plain `WebAssembly` API + a ~30-line WASI shim |
| needs | any recent emcc | **Zig >= 0.16** |

The Zig path produces a single self-contained `.wasm` with no generated
JavaScript at all — the whole browser deliverable is that file plus
`src/htmlsanitizer-wasi.mjs`. Use it if you would rather not carry the emsdk,
or want the smaller toolchain in CI.

```sh
./build-zig.sh                    # zig on PATH
ZIG=/path/to/zig ./build-zig.sh
```

### Version requirements, and what upstream fixed

**Zig >= 0.16.** 0.13 shipped no `bits/setjmp.h` for wasm targets at all, so
the Aether runtime could not compile.

**ae >= 0.553.** This backend used to carry two local workarounds — a patched
copy of `aether_panic.c` and a `_longjmp` trap stub. **Both are gone**; the
fixes landed upstream as the `__wasi__` arms in `aether_panic.h`/`.c`. The
script version-gates on this and points you at `./build.sh` if your `ae` is
older.

Two things `build-zig.sh` still passes explicitly, both matching what ae's own
`--target=wasm32-wasi` backend does:

- **`-D__wasm_exception_handling__=1`** satisfies wasi-libc's `setjmp.h` guard.
  It deliberately does *not* enable the EH backend
  (`-mllvm -wasm-enable-sjlj`): that lowers `setjmp`/`longjmp` to
  `__wasm_setjmp`/`__wasm_longjmp`, which live in wasi-libc's
  `setjmp/wasm32/rt.c` — a file zig's bundled wasi-libc does not compile. So
  enabling it only moves the link error. With ae >= 0.553 the runtime does not
  reference `longjmp` at all on wasi.
- **`-D_WASI_EMULATED_SIGNAL`** (+ the matching `-l`) and
  **`-DAETHER_NO_THREADING`**. WASI has no usable threads, and its
  `pthread_create` *stub* returns `EAGAIN` rather than failing to link — so a
  threaded build would hang on the scheduler readiness barrier rather than
  erroring.

The only remaining shim is `src/regex_stub.c`, and that is our choice (PCRE2 is
dead code here), not a toolchain gap.

### `ae build --target=wasm32-wasi` builds executables directly

As of ae 0.553 you do not need this script at all for a *program*:

```sh
ae build --target=wasm32-wasi core_tests/probe.ae -o probe.wasm
node --experimental-wasi-unstable-preview1 run.mjs probe.wasm
```

Verified: the engine's 12-case behavioural suite and the 47-vector XSS suite
both run green as wasm32-wasi under Node's WASI, with identical results to
native. `build-zig.sh` still exists because `--emit=lib` is not yet supported
for cross targets — a *library* of exports (what a browser binding needs) still
has to be linked by hand from `--emit=csrc` output.

## API

Mirrors the other bindings; see [`../docs/abi.md`](../docs/abi.md).

```js
const s = await HtmlSanitizer.create();
// or point at a custom .wasm location:
const s = await HtmlSanitizer.create({ wasmUrl: '/static/htmlsanitizer.wasm' });

s.sanitize(html, baseUrl);          // the main entry point
s.sanitizeDocument(html, baseUrl);
s.setInnerHTML(el, html, baseUrl);  // convenience for the DOM case

s.allowedTags.add('my-widget');     // set-like: add/delete/has/clear/size, iterable
s.allowedTags.delete('marquee');
s.allowedSchemes.toArray();         // ['http', 'https']
// also: allowedAttributes, allowedCssProperties, allowedClasses, uriAttributes

s.keepChildNodes = true;            // flags
s.allowDataAttributes = true;

s.close();                          // release the wasm-side handle
```

`create()` instantiates the wasm module once per page and caches it; further
sanitizers share that instance, so only the first `await` pays the load.

### Callbacks are not exposed

Checks 10 and 11 of the [conformance suite](../docs/conformance.md) — the
`on_removing_*` and `on_filter_url` hooks — are **not** available here.
Emscripten can do it via `addFunction`, but that needs `-sALLOW_TABLE_GROWTH`
and a reserved function table, which costs bundle size for a feature a DOM
sanitizer rarely wants. Deliberate omission, not an oversight; everything
else in the ABI is exposed. Open an issue if you need them.

## Tests

```sh
node --test test/conformance.test.mjs        # 22 checks, emcc build
node --test test/conformance-wasi.test.mjs   # the same 22, zig build
aeb wasm/.tests.ae                           # build + test both, from the repo root
```

Covers the conformance checks that apply, the security regressions, and
wasm-specific concerns: UTF-8 across the boundary, `ALLOW_MEMORY_GROWTH` under
a large document, and use-after-close.

## Demo

`example/index.html` is a live playground — paste untrusted HTML, watch it get
cleaned, and see it rendered through `innerHTML`. Serve it (module imports need
HTTP, not `file://`):

```sh
python3 -m http.server -d .        # then open /example/
```

## Memory

The engine has a small per-`sanitize()` allocation it does not reclaim (see
the root README's known issues) — engine-side, shared by every binding. In a
page-lifetime sanitizer this is irrelevant. In a long-running SPA that
sanitizes continuously, `close()` the handle periodically, or create one per
view and close it on teardown; the wasm heap grows otherwise.
