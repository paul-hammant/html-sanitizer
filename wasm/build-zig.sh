#!/usr/bin/env bash
# Build the HtmlSanitizer engine to WebAssembly using `zig cc` — no Emscripten.
#
# vs build.sh (emcc):
#   + no ~1GB emsdk; one ~50MB zig tarball cross-compiles to wasm32
#   + output is a SINGLE self-contained .wasm with NO JS glue file — the page
#     drives it with the plain WebAssembly API (see src/htmlsanitizer-wasi.mjs)
#   - slightly larger (~87KB vs ~62KB)
#   - needs Zig >= 0.16 (0.13 shipped no bits/setjmp.h for wasm at all)
#   - needs ae >= 0.553 (the __wasi__ arms in aether_panic.h/.c). Earlier ae
#     required two local shims here — a patched copy of aether_panic.c and a
#     _longjmp trap stub. BOTH ARE GONE: the fixes landed upstream. The only
#     shim left is src/regex_stub.c, and that is our choice, not a gap.
#
# Usage:  ./build-zig.sh            # zig on PATH
#         ZIG=/path/to/zig ./build-zig.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/dist"
WORK="$HERE/build/zig"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

ZIG="${ZIG:-$(command -v zig || true)}"
[ -n "$ZIG" ] || die "zig not found. Install Zig >= 0.16 (https://ziglang.org/download/) or set ZIG=/path/to/zig."

ZV="$("$ZIG" version)"
case "$ZV" in
    0.1[0-5].*|0.[0-9].*)
        die "zig $ZV is too old. Need >= 0.16 — earlier versions ship no
bits/setjmp.h for wasm targets, so the Aether runtime cannot compile." ;;
esac

command -v aetherc >/dev/null 2>&1 || die "aetherc not found — install Aether (see ../bootstrap.sh)."

# ae >= 0.553 carries the __wasi__ arms in aether_panic.h/.c. Below that the
# runtime references _longjmp (unimplemented in wasi-libc) and installs a
# sigaction crash handler wasi has no headers for, and this script would need
# the local patches it used to carry.
AEV="$(ae --version 2>/dev/null | head -1 | sed -E 's/^ae ([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
case "$AEV" in
    0.[0-9]|0.[0-9].*|0.[1-4][0-9][0-9]*|0.5[0-4][0-9]*)
        die "ae $AEV is too old for the wasi backend. Need >= 0.553 (the __wasi__
setjmp/panic arms). Upgrade, or use ./build.sh (Emscripten) instead." ;;
esac
# Locate the Aether SOURCE root — the dir holding runtime/ and std/.
# Two layouts, the same distinction ae itself draws internally:
#   installed:  <prefix>/bin/ae   -> <prefix>/share/aether/{runtime,std}
#   dev tree:   <repo>/build/ae   -> <repo>/{runtime,std}
# (Getting this wrong is exactly the bug filed as
#  aether/asks/target-wasm-omits-share-aether-on-user-prefix.md.)
_AE_BIN_DIR="$(dirname "$(readlink -f "$(command -v ae)")")"
AE=""
for cand in "$_AE_BIN_DIR/../share/aether" "$_AE_BIN_DIR/.."; do
    if [ -d "$cand/runtime" ] && [ -d "$cand/std" ]; then
        AE="$(cd "$cand" && pwd)"
        break
    fi
done
[ -n "$AE" ] || die "could not locate the Aether source root (runtime/ + std/) from $(command -v ae)."

mkdir -p "$OUT" "$WORK"

# ---- 1. Aether -> portable C (mangled aether_ exports; see build.sh) ----
say "generating C from core/embed.ae"
( cd "$ROOT/core" && aetherc --emit=csrc embed.ae "$WORK/hs.c" )

# ---- 2. runtime sources (same minimal set as build.sh) ----
RT="
runtime/scheduler/aether_scheduler_coop.c runtime/scheduler/scheduler_optimizations.c
runtime/config/aether_optimization_config.c
runtime/memory/aether_arena.c runtime/memory/aether_pool.c
runtime/memory/aether_memory_stats.c runtime/memory/aether_arena_optimized.c
runtime/utils/aether_bounds_check.c runtime/utils/aether_test.c
runtime/utils/aether_cpu_detect.c runtime/utils/aether_simd_vectorized.c
runtime/aether_runtime_types.c runtime/aether_locale_num.c runtime/aether_runtime.c
runtime/aether_numa.c runtime/aether_host.c runtime/aether_resource_caps.c
runtime/actors/aether_send_buffer.c runtime/actors/aether_send_message.c
runtime/actors/aether_unwind.c runtime/actors/aether_actor_thread.c
std/string/aether_string.c std/math/aether_math.c std/alloc/aether_alloc.c
std/collections/aether_collections.c std/collections/aether_set.c
std/collections/aether_stringseq.c std/strbuilder/aether_strbuilder.c
std/bytes/aether_bytes.c std/mem/aether_mem.c std/io/aether_io.c std/log/aether_log.c
"
SRCS="$AE/runtime/actors/aether_panic.c $HERE/src/regex_stub.c"
for f in $RT; do
    [ -f "$AE/$f" ] && SRCS="$SRCS $AE/$f"
done

INCS=$(find "$AE/runtime" "$AE/std" "$AE/include" -name '*.h' 2>/dev/null \
       | sed 's|/[^/]*$||' | sort -u | sed 's|^|-I|' | tr '\n' ' ')

EXPORTS=""
for s in new free free_string sanitize sanitize_document allow disallow \
         is_allowed clear count item_at set_keep_child_nodes get_keep_child_nodes \
         set_allow_data_attributes get_allow_data_attributes abi_version; do
    EXPORTS="$EXPORTS -Wl,--export=aether_hs_embed_$s"
done

# -D__wasm_exception_handling__=1 satisfies wasi-libc's setjmp.h guard. It does
# NOT switch on the EH backend (-mllvm -wasm-enable-sjlj) — that lowers
# setjmp/longjmp to __wasm_setjmp/__wasm_longjmp, which zig's bundled wasi-libc
# does not compile, so it only moves the link error. ae >= 0.553's __wasi__ arm
# in aether_panic.h makes the runtime not reference longjmp at all.
# -DAETHER_NO_THREADING matches what ae's own wasi backend passes: wasi has no
# usable threads, and its pthread_create STUB returns EAGAIN rather than failing
# to link — so a threaded build would hang on the scheduler readiness barrier
# rather than erroring.
say "compiling to wasm32-wasi (zig $ZV)"
# shellcheck disable=SC2086
"$ZIG" cc -target wasm32-wasi -Oz \
    -D__wasm_exception_handling__=1 -DAETHER_NO_THREADING \
    -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_MMAN \
    -ffunction-sections -fdata-sections \
    "$WORK/hs.c" "$ROOT/core/_embed_support.c" \
    $SRCS -I"$AE" $INCS \
    -o "$OUT/htmlsanitizer-wasi.wasm" \
    -Wl,--no-entry -Wl,--strip-all -Wl,--gc-sections \
    -Wl,--export=malloc -Wl,--export=free $EXPORTS \
    -lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-mman \
    -Wno-everything

cp "$HERE/src/htmlsanitizer-wasi.mjs" "$OUT/" 2>/dev/null || true

say "built:"
ls -la "$OUT/htmlsanitizer-wasi.wasm" | awk '{printf "    %-34s %8d bytes  (no JS glue)\n", $NF, $5}'
