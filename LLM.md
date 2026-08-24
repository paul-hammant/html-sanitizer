# Notes to self (LLM assisting on html-sanitizer)

Not a CLAUDE.md — short, opinionated, written for a future LLM picking up
mid-task. Re-read at the start of every session. The code is the source of
truth; this is the map so your *first* attempt lands clean.

## What this is, in one paragraph

An XSS-scrubbing HTML sanitizer — a C# port (Michael Ganss's
[HtmlSanitizer](https://github.com/mganss/HtmlSanitizer)) rewritten in pure
Aether — shipped as a **one-engine-many-thin-bindings** monorepo, the same
shape as the sibling [`servirtium-vcr`](https://github.com/servirtium/servirtium-vcr).
The engine is `core/htmlsanitizer.ae` (~1540 lines: HTML5 tokenizer, DOM, CSS
inline-style parser, URL resolver, allow-lists, callbacks). `core/embed.ae`
wraps it in a flat C ABI and `ae build --emit=lib` produces
`core/native/libhtmlsanitizer.so`. Every language directory is a thin FFI shim
over that one artifact. Built by **aeb**; each binding is one `.tests.ae` leaf
that deps `core/.build.ae`.

## The one rule

**Bindings carry no sanitizer logic.** A binding opens a handle, configures
allow-lists and callbacks, calls sanitize, and frees. Anything smarter than
marshalling belongs in `core/`. If you find yourself parsing HTML, resolving a
URL, or deciding whether a tag is allowed inside a binding — stop, that is the
engine's job, and duplicating it is exactly the class of drift this layout
exists to prevent.

## Why one engine (say this if asked to "just port it to X")

A sanitizer is a security boundary. Per-language reimplementations mean
per-language XSS holes, and a bypass has to be re-found and re-fixed in every
one. Here there is a single tokenizer/DOM/CSS/URL path; fix a bypass once and
every binding inherits it on rebuild.

## The C ABI

Full reference: `docs/abi.md`. `core_tests/abi_smoke.c` is a complete working
consumer in C (dlopen + dlsym only) and is the best thing to read before
writing a binding. `rust/src/native.rs` is the canonical 1:1 symbol table in a
real binding.

Facts that bit during the build-out, all still true:

- **Exports are `aether_hs_embed_<name>`** (the `--emit=lib` mangling of
  `hs_embed_<name>`). The C helpers in `_embed_support.c` are deliberately
  named `hs_raw_*` — an earlier `hs_embed_free` in C **shadowed** the Aether
  `hs_embed_free` export, so the handle-free symbol silently never got
  emitted and every host leaked a whole sanitizer per handle. If you add a C
  helper, keep it out of the `hs_embed_` namespace.
- **Callback widths are C `int`, not `long`.** Codegen emits the engine's
  closure calls as `int(*)(...)`. A `long` declaration on the host side is a
  4-vs-8-byte mismatch on LP64 → garbage `reason`, corrupted stack args. The
  doc comment in `embed.ae` used to say `long`; it lied, and it's fixed.
- **Aether strings crossing a `const char*` slot are `AetherString*`, not C
  strings.** They have a magic header, and reading them raw gives mojibake.
  The trampolines call `aether_string_data()` inbound and `string_new()`
  outbound. This is why the style hook and `filter_url` initially returned
  garbage while every other check passed.
- **Callbacks work at all** because `_embed_support.c` builds a box in
  codegen's own `_AeClosure` layout (`{void(*fn)(void); void* env;}`), puts a
  trampoline in `.fn` and the host's function pointer + `user_data` in
  `.env`. That is the whole trick that gives 21 bindings real hooks over one
  ABI. Non-zero return from a `removing_*` hook **cancels** the removal.
- **`attr_set_value` copies.** It used to alias the host's buffer, which
  dangles the moment a Java confined `Arena` or a Go `C.CString` is freed.
- **`set.items()` has no per-entry accessor in std.set** (its own regression
  test only null-checks the snapshot), so `hs_embed_keys_at` reads the
  `MapKeys` struct directly in C. If std.set ever grows a real accessor,
  that helper can go.

## The WASM target (`wasm/`)

The one binding that does NOT consume `libhtmlsanitizer.so` — a browser can't
`dlopen` it. `wasm/build.sh` recompiles the same engine sources to wasm32 via
Emscripten, so the DOM gets the same logic, not a JS rewrite. ~62 KB.

Two traps, both already paid for:

- **Use `aetherc --emit=csrc`, not plain `aetherc`.** Only that mode applies
  the `aether_` export mangling. Plain codegen emits bare `hs_embed_new`, and
  the link dies with "symbol exported via --export not found" — which looks
  like a wasm problem and isn't.
- **Don't feed it `share/aether/MANIFEST`.** `multicore_scheduler.c` fails a
  `Mailbox` alignment `static_assert` on wasm32. `build.sh` mirrors the
  `RUNTIME_FILES` list from Aether's own `make ci-wasm` instead, plus
  strbuilder/bytes/mem/set/stringseq/alloc.

PCRE2 is stubbed (`wasm/src/regex_stub.c`) because the engine's only regex use
is `disallow_css_property_value_regex`, which **no C-ABI caller can set** —
there is no way to hand a compiled `std.regex` across the FFI, so the field is
always null in a `--emit=lib` build and the regex calls are dead code there.
(NB: the field IS wired in the engine — an earlier note here wrongly said
"never wired". `sanitize_css_style_attribute` consults it and drops matching
declarations; proven with `^rgba\(0.*`. It is unreachable from the bindings,
not unimplemented.) If a C-ABI setter is ever added, this stub must go and
PCRE2 becomes an emscripten port / a real wasi build input.

**Two backends, both wired and tested.** `build.sh` (emcc, ~62KB + JS glue) and
`build-zig.sh` (`zig cc -target wasm32-wasi`, ~85KB, NO glue — driven by the
plain `WebAssembly` API). `wasm/.tests.ae` runs whichever is installed, both if
both, asserting the SAME 22 checks against each; a divergence is a build bug.

The Zig path needs **Zig >= 0.16** (0.13 shipped no `bits/setjmp.h` for wasm at
all) and **ae >= 0.553**. `build-zig.sh` version-gates on both.

**Two local workarounds are GONE — don't reintroduce them.** This backend used
to patch a scratch copy of `aether_panic.c` and ship a `_longjmp` trap stub
(`wasm/src/wasi_longjmp_stub.c`, deleted). Both fixes landed upstream as the
`__wasi__` arms in `aether_panic.h`/`.c`. The only shim left is
`wasm/src/regex_stub.c`, which is our choice (PCRE2 is dead code here), not a
toolchain gap.

Still passed explicitly, matching ae's own `--target=wasm32-wasi` backend:
- `-D__wasm_exception_handling__=1` satisfies wasi-libc's `setjmp.h` guard. Do
  NOT "fix" this by enabling the EH backend (`-mllvm -wasm-enable-sjlj`): that
  lowers setjmp/longjmp to `__wasm_setjmp`/`__wasm_longjmp`, which live in
  wasi-libc's `setjmp/wasm32/rt.c` — a file zig's bundled wasi-libc does not
  compile, so it only moves the link error.
- `-D_WASI_EMULATED_SIGNAL` (+ process-clocks/mman siblings) and
  `-DAETHER_NO_THREADING`. WASI's `pthread_create` STUB returns `EAGAIN`
  rather than failing to link, so a threaded build hangs on the scheduler
  readiness barrier instead of erroring.

**`ae build --target=wasm32-wasi` now builds executables directly** (ae 0.553),
so for a *program* you need no script at all — verified: the 12-case
behavioural suite and the 47-vector XSS suite both run green under Node's WASI,
identical to native. `build-zig.sh` survives only because `--emit=lib` is not
yet supported for cross targets, so a *library of exports* (what a browser
binding needs) must still be hand-linked from `--emit=csrc` output.

Callbacks (conformance checks 10/11) are deliberately not exposed: it needs
`addFunction` + `-sALLOW_TABLE_GROWTH` + a reserved table, for a feature a DOM
sanitizer rarely wants.

## Build/test (aeb)

- `aeb` is at `~/.local/bin/aeb`, **not on `PATH`** in a fresh shell.
- `aeb core/.build.ae` builds the engine; every binding leaf deps it and gets
  the path via `build.dep_artifact(... "shared_lib")`, handed to the binding
  as **`HTMLSANITIZER_LIB`**.
- `aeb .presubmit.ae` runs everything.
- **`aeb` exits 0 even when a leaf returns 1** (reproduced with a 3-line
  failing leaf — it is an aeb bug, not ours). **Read
  `target/.aeb/logs/<label>.log`**; every leaf ends with an explicit
  `PASS` / `SKIPPED` / failure line. Do not trust exit status, and do not
  report a binding green because `aeb` returned 0.
- **Never run two top-level `aeb` invocations concurrently** — they clobber
  the shared `target/` workspace. Sequential only.
- A binding whose toolchain is missing **skips loudly** and returns 0. That is
  deliberate so a partial toolchain set still gives a meaningful run — but it
  means "no failures" ≠ "everything ran". Check for `SKIPPED` lines.

## Two gates, and what each proves

- `core_tests/.tests.ae` → `probe.ae`, the 12 behavioural cases ported from
  the C# suite, in pure Aether. Proves the **engine**.
- `core_tests/.abi.ae` → `abi_smoke.c`, pure C over dlopen. Proves the **ABI**
  — all six callback shapes, the caller-owned-string contract, allow-list
  enumeration, handle independence. If this is green, a binding failure is a
  binding bug.

Per-binding suites mirror `docs/conformance.md` — twelve checks that sample
each *kind* of value crossing the FFI. They are not sanitizer tests; the
behavioural cases run once, in the engine.

## Known issues (don't "discover" these again)

- **Per-`sanitize()` growth, ~0.2–0.3 kB/call.** Engine-side: `heap.free` on a
  `ptr` can't decrement refcounted `string` fields nested in heap-boxed
  structs (`DomNode.name/value`, `DomAttr.name/value`). Measured identical
  from pure C and from bindings, so never diagnose it as a binding bug. The
  README's fix hint (reassign fields to `""` before `heap.free`) is the route
  if someone wants to close it.
- **The per-*handle* leak is fixed** — `populate_defaults` built three big
  `*StringSeq` literals and never freed them (~10 kB per `new()`, even with
  zero sanitize calls). Now `string_seq_free`d. 20k handle cycles went from
  ~300 MB to ~3 MB RSS. Don't reintroduce a seq literal without a free.
- **`on_removing_css_class` never fires.** The engine declares, populates and
  frees the slot but has no call site — a gap in the original port. The ABI
  deliberately omits it rather than expose a dead hook. Wiring it up in
  `sanitize_attributes` (where the `class` attribute is filtered) is the fix.

## Toolchain reality on this box

Installed and genuinely exercised: python3, ruby, go, node, JDK 24, cargo,
dart, lua (5.4 dev headers; note Debian ships a 5.3 *interpreter*, so `lua/`
compiles a small 5.4 host for tests). Kotlin/Groovy needed newer compilers
than Debian's (Debian's kotlinc 1.3 / groovy 2.4 can't read JDK 22+ bytecode)
— the leaves probe for a usable one rather than trusting `command -v`.
Absent: dotnet, php, scala, clojure, erlang/elixir/gleam, ghc, nim, zig,
Pharo. Those leaves skip loudly.

## Repo geography

`core/` engine + ABI + the ~200 lines of C that can't be Aether.
`core_tests/` the two gates. `<lang>/` one binding each, with its own README.
`docs/` `abi.md` (the contract) and `conformance.md` (the 12 checks).
`.presubmit.ae` the aggregate target set.

## Upstream siblings

`../aether` (the language; its `LLM.md` is the deep reference — read the
"Idioms that keep biting" section before touching `.ae` code), `../aeb` (the
build runner), `../servirtium-vcr` (the layout this repo copies; its `LLM.md`
explains the one-engine-many-bindings rationale at length).
