# wasm/ — TODO

**Status (2026-08-23):** `ae build --target=wasm32-wasi --emit=lib` works
against a **pristine** aether 0.577.0 — no local patches. It builds a module
with all 40 `aether_hs_embed_*` exports that passes our full 22-check WASI
conformance suite. The setjmp link blocker we filed is **fixed upstream**
(aether #1728, released in 0.577.0).

**One thing still keeps `build-zig.sh` alive: size.**

| | size |
|---|---|
| `ae build --emit=lib --target=wasm32-wasi` | 2,041,038 |
| …after hand-stripping `.debug*` + `name` | ~324,000 |
| `build-zig.sh` (`-Oz --strip-all --gc-sections`) | 85,148 |

**82% of the native artifact is DWARF** (`.debug_loc` 25%, `.debug_info` 25%,
`.debug_line` 23%); hand-stripping is safe — still 22/22. The remaining 3.8× is
`-Oz` vs `-O2` plus dead code: zig exports 20 symbols, native 46, because
`ae build` has no `--gc-sections`/`--strip-all`/`-Oz` mode and no linker-flag
passthrough.

Notably this is **wasm-path-specific**: the native `.so` from the same source
carries *zero* debug sections, so `-O2` is behaving correctly there and
something in the zig cross path adds `-g`. Filed as
`aether/asks/emit-lib-ships-debug-info-with-no-size-mode.md`.

2 MB is fine server-side and disqualifying in a browser, which is most of why
this directory exists — so **retire `build-zig.sh` when the size gap closes**,
not before. The script works today and we are not blocked.

The MANIFEST stopgap below is moot for the native path (which derives its own
runtime set) but still applies to `build.sh` (emcc) and to `build-zig.sh` for
as long as it lives.

## 0. DO NOW: replace the hand-rolled runtime list with a MANIFEST-derived one

**This is not "wait for --emit=lib" — do it before then.** The Aether maintainer
flagged that our hand-picked `RUNTIME_FILES` list is actively dangerous, and I
verified it: `make ci-wasm`'s list is a **literal** (the *Emscripten* set,
`Makefile:2891`), while Aether's zig cross path assembles its set from the
**MANIFEST** at build time (`ae_cross.c:226`). So our scripts "mirror ci-wasm" —
the emcc literal — even in `build-zig.sh`, which is the wrong source of truth.
The two were never the same list. A new runtime `.c` in Aether drops out of our
build **silently** — the failure mode is a missing symbol at link or, worse, a
subtly wrong runtime, not an error.

Until `--emit=lib` lands, drive both scripts off the MANIFEST (the rule Aether
actually maintains), not a literal:

```sh
# STOPGAP for aether/asks/wasm-emit-lib-with-exports.md — DELETE when --emit=lib lands.
RT_SRCS=$(sed -n 's/\.c$/&/p' "$(ae --print-root)/share/aether/MANIFEST" \
          | sed 's|multicore_scheduler\.c|aether_scheduler_coop.c|')
```

Still a duplicate of the *rule* (the coop-scheduler swap), but not of the
*contents* — so a new runtime file can't silently vanish from the build. Mark it
a stopgap in a comment so it gets deleted, not inherited.

### Why the scripts exist (and why the literal list is a smell)

Both `build.sh` (emcc) and `build-zig.sh` (zig) hand-roll the wasm build:
`aetherc --emit=csrc`, then a **hand-picked minimal runtime source list**, then
`emcc` / `zig cc -target wasm32-wasi` with an `-Wl,--export=` set. The list
exists only to avoid `multicore_scheduler.c` (whose `Mailbox` static_assert
fails on wasm32). Duplicating Aether's runtime curation as a literal is the
defect §0 fixes; folding it into `ae build` entirely is what `--emit=lib` does.

### The right fix is in Aether, and it's narrow

Filed as `aether/asks/wasm-emit-lib-with-exports.md`. Measured on ae 0.556.0:

- `ae build --target=wasm32-wasi <exe>` already bundles the runtime correctly
  (944 KB `.wasm`, real `aether_*` inside). Aether does the coop-scheduler swap
  itself (`cross_use_coop_scheduler`, `tools/ae_cross.c:315`) — the exact
  `multicore_scheduler.c`-omit workaround these scripts hand-roll.
- The only missing mode is **`--emit=lib` for wasm** (gate at `ae.c:5134`).
  Cross `--emit=lib` machinery already exists for Apple dylibs in
  `run_cross_build`; wasm needs one more branch: `-Wl,--no-entry
  -Wl,--gc-sections` + the export set, reusing the exe path's runtime assembly.

**The export list comes from the source, not a flag.** The maintainer's
correction (in our favour): `core/embed.ae` already declares its ABI via
`exports(...)`, which emits a catalog (`aether_name`/`c_symbol`/`signature`) with
the `aether_` mangling already applied — the same declarations our scripts derive
`$EXPORTS` from today. `--emit=lib` reads that catalog and synthesises the
`-Wl,--export=` set itself, so the whole build is:

```
ae build --target=wasm32-wasi --emit=lib core/embed.ae -o htmlsanitizer.wasm
```

No `--export=` flags, no export enumeration to keep in sync — the ABI is written
down in exactly one place (`exports(...)` in the source). `malloc`/`free` come
along by default. Aether bundles the runtime; no runtime source list, no 43-dir
include scrape. (If we ever need to export a symbol NOT in `exports(...)`, the
maintainer will add a `--export=` override — but our scripts derive from the same
declarations, so we don't.)

The emcc side of Aether was already correct on runtime curation — it *pioneered*
the coop-scheduler swap the zig path mirrors. It shares the same `--emit=lib`
gap, no more. **zig lands first** (no emsdk, cleanest duplication win); the emcc
half (`--target=wasm`, `-sEXPORTED_FUNCTIONS`) is a deliberate follow-up.

**Timing:** the maintainer notes the wasm cross path has churned this week
(source-root fix, scheduler substitution, a computed-goto codegen guard) and
would rather land `--emit=lib` on a quiet base than stack it on an open PR — so
it may trail the current queue. The §0 MANIFEST-derived stopgap holds until then.
**If we're blocked, say so and they'll prioritise.**

### Sequence

1. **Aether:** land `wasm32-wasi --emit=lib`, driven off the `exports(...)`
   catalog, reusing the existing runtime assembly; un-gate `ae.c:5134`; add a
   regression test that links a wasm lib and asserts the exports are present.
2. **aeb:** add a thin `aether.wasm_lib` builder — a couple of setters (`source`,
   `target`, `output`, an extra-C-source for `regex_stub.c`) threading
   `--target`/`--emit=lib` into the existing `ae build` shell-out (same shape as
   this cycle's `aether.program` `target()` work). No `export` setter — exports
   come from the source. A few dozen lines; aeb never sees a runtime list.
3. **here:** replace the scripts with two aeb leaves —
   `.zig_wasm_build.ae` (`target("wasm32-wasi")`, lands first) and later
   `.emscripten_build.ae` (`target("wasm")`) — then **delete `build-zig.sh`**,
   and `build.sh` once the emcc follow-up lands.

Target shape (leaf; the emcc leaf differs only in `target(...)`):

```aether
import build
import aether
import aether (source, target, output)

aeb(cap) {
    b = build.start()
    aether.wasm_lib(b) {
        source("../core/embed.ae")     // exports(...) IN this source name the ABI
        target("wasm32-wasi")          // or "wasm" for the emcc follow-up
        c_source("src/regex_stub.c")   // our stub, not a gap — extra C on the node
        output("htmlsanitizer-wasi.wasm")
    }
}
```

No `export(...)` lines: the ABI is declared once, by `exports(...)` in
`core/embed.ae`, and `ae build --emit=lib` reads it.

### PREREQUISITE: `core/embed.ae` must declare `exports(...)`

Checked, and this is real work, not free: **`core/embed.ae` has no `exports(...)`
block today.** Its ABI functions are plain top-level defs (`hs_embed_new() ->
ptr`, `hs_embed_sanitize(...)`, …), and the `aether_hs_embed_*` C symbols come
from the existing mangling; `build-zig.sh` enumerates them by hand in its
`$EXPORTS` loop. The maintainer's `--emit=lib` reads the `exports(...)` catalog —
so with no such block, it has nothing to synthesise the `--export=` set from.

Before `--emit=lib` helps us, add an `exports(...)` to `core/embed.ae` naming the
same ~16 functions the scripts list (`new`, `free`, `free_string`, `sanitize`,
`sanitize_document`, `allow`, `disallow`, `is_allowed`, `clear`, `count`,
`item_at`, `set/get_keep_child_nodes`, `set/get_allow_data_attributes`,
`abi_version`). This is a net win — it moves the ABI to a single declared place
(what the other bindings should agree with anyway) instead of a shell loop — but
it must land first, and the native/JVM bindings should be re-checked against it.

### Parity to confirm before deleting the scripts

- The `exports(...)` block added above names exactly the script's `$EXPORTS` /
  `EXPORTED_FUNCTIONS` set — cross-check once so nothing drops.
- `_malloc`/`_free` are exported by default — a wasm consumer needs them to
  marshal strings. Confirm the emitted module exports them.
- The emitted module drives from the plain `WebAssembly` API for the zig/WASI
  path (`src/htmlsanitizer-wasi.mjs`) and the emcc glue for the emcc follow-up.

### Cross-refs

- `aether/asks/wasm-emit-lib-with-exports.md` — the actual fix (Aether).
- `aeb/asks/cross-compile-the-aether-runtime-for-wasm.md` — the original ask;
  its "this is really an Aether ask" diagnosis was right. Its proposed aeb-side
  `c.shared_object(target=…)` grammar is NOT the path — Aether curates the
  runtime, so aeb stays a thin driver.
