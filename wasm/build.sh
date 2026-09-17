#!/usr/bin/env bash
# Build the HtmlSanitizer core to WebAssembly.
#
# Unlike every other binding here, this one does NOT load
# core/native/libhtmlsanitizer.so — a browser cannot dlopen a native .so.
# Instead it compiles the SAME sanitizer core sources to wasm32 via Emscripten, so
# the sanitizer running in the DOM is byte-for-byte the same logic as the
# native bindings, not a JS reimplementation. That is the whole point: a
# second implementation would mean a second set of XSS holes.
#
# Two things make this build different from a naive "compile everything":
#
#   1. `aetherc --emit=csrc` (not plain `aetherc`) — only that mode applies
#      the `aether_` export mangling, so the symbols wasm-ld is asked to
#      --export actually exist. Plain codegen emits bare `hs_embed_new`.
#   2. A MINIMAL runtime source list, not share/aether/MANIFEST. The full
#      manifest pulls in the multicore scheduler, whose `Mailbox` alignment
#      static_assert fails on wasm32. This list mirrors the RUNTIME_FILES
#      in Aether's own `make ci-wasm`, plus what the sanitizer needs
#      (strbuilder / bytes / mem / set / stringseq / alloc).
#
# PCRE2 is stubbed (src/regex_stub.c): the sanitizer core's only regex use is the
# never-wired disallow_css_property_value_regex field, always null. Stubbing
# keeps the whole PCRE2 port out of the bundle for no behavioural change.
#
# Usage:  ./build.sh            # needs emcc on PATH
#         EMSDK=/path ./build.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/dist"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- toolchain ----
if ! command -v emcc >/dev/null 2>&1; then
    if [ -n "${EMSDK:-}" ] && [ -f "$EMSDK/emsdk_env.sh" ]; then
        # shellcheck disable=SC1091
        source "$EMSDK/emsdk_env.sh" >/dev/null 2>&1
    fi
fi
command -v emcc >/dev/null 2>&1 || die "emcc not found. Install the Emscripten SDK:
    git clone https://github.com/emscripten-core/emsdk
    cd emsdk && ./emsdk install latest && ./emsdk activate latest
    source ./emsdk_env.sh
(Or set EMSDK=/path/to/emsdk and re-run.)

Note: ./build-zig.sh avoids the ~1GB emsdk download entirely — it uses
\`zig cc -target wasm32-wasi\` and emits a single self-contained .wasm with no
JS glue. It needs Zig >= 0.16 and ae >= 0.553."

command -v aetherc >/dev/null 2>&1 || die "aetherc not found — install Aether (see ../bootstrap.sh)."

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

mkdir -p "$OUT" "$HERE/build"

# ---- 1. Aether -> portable C (with the aether_ export mangling) ----
say "generating C from core/embed.ae"
( cd "$ROOT/core" && aetherc --emit=csrc embed.ae "$HERE/build/hs.c" )

# ---- 2. runtime sources ----
# Mirrors Aether's own `make ci-wasm` RUNTIME_FILES. Do NOT swap this for
# share/aether/MANIFEST: multicore_scheduler.c fails a Mailbox alignment
# static_assert on wasm32.
RT="
runtime/scheduler/aether_scheduler_coop.c runtime/scheduler/scheduler_optimizations.c
runtime/config/aether_optimization_config.c
runtime/memory/aether_arena.c runtime/memory/aether_pool.c
runtime/memory/aether_memory_stats.c runtime/memory/aether_arena_optimized.c
runtime/utils/aether_bounds_check.c runtime/utils/aether_test.c
runtime/utils/aether_cpu_detect.c runtime/utils/aether_simd_vectorized.c
runtime/aether_runtime_types.c runtime/aether_locale_num.c runtime/aether_runtime.c
runtime/aether_numa.c runtime/aether_host.c runtime/aether_resource_caps.c
runtime/actors/aether_panic.c runtime/actors/aether_send_buffer.c
runtime/actors/aether_send_message.c runtime/actors/aether_unwind.c
runtime/actors/aether_actor_thread.c
std/string/aether_string.c std/math/aether_math.c std/alloc/aether_alloc.c
std/collections/aether_collections.c std/collections/aether_set.c
std/collections/aether_stringseq.c std/strbuilder/aether_strbuilder.c
std/bytes/aether_bytes.c std/mem/aether_mem.c std/io/aether_io.c std/log/aether_log.c
"
SRCS=""
for f in $RT; do
    [ -f "$AE/$f" ] && SRCS="$SRCS $AE/$f"
done

# Header dirs are scattered across runtime/* and std/*; collect them all.
INCS=$(find "$AE/runtime" "$AE/std" "$AE/include" -name '*.h' 2>/dev/null \
       | sed 's|/[^/]*$||' | sort -u | sed 's|^|-I|' | tr '\n' ' ')

# ---- 3. the exported ABI surface ----
EXPORTED_FUNCTIONS='["_aether_hs_embed_new","_aether_hs_embed_free","_aether_hs_embed_free_string","_aether_hs_embed_sanitize","_aether_hs_embed_sanitize_document","_aether_hs_embed_allow","_aether_hs_embed_disallow","_aether_hs_embed_is_allowed","_aether_hs_embed_clear","_aether_hs_embed_count","_aether_hs_embed_item_at","_aether_hs_embed_set_keep_child_nodes","_aether_hs_embed_get_keep_child_nodes","_aether_hs_embed_set_allow_data_attributes","_aether_hs_embed_get_allow_data_attributes","_aether_hs_embed_abi_version","_malloc","_free"]'

say "compiling to wasm32 (emcc $(emcc --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1))"
# shellcheck disable=SC2086
emcc -O3 \
    "$HERE/build/hs.c" "$ROOT/core/_embed_support.c" "$HERE/src/regex_stub.c" \
    $SRCS -I"$AE" $INCS \
    -o "$OUT/htmlsanitizer.js" \
    -sEXPORTED_FUNCTIONS="$EXPORTED_FUNCTIONS" \
    -sEXPORTED_RUNTIME_METHODS='["UTF8ToString","stringToNewUTF8","lengthBytesUTF8","stringToUTF8"]' \
    -sALLOW_MEMORY_GROWTH=1 \
    -sMODULARIZE=1 \
    -sEXPORT_NAME=createHtmlSanitizer \
    -sEXPORT_ES6=1 \
    -sENVIRONMENT=web,worker,node \
    -sFILESYSTEM=0 \
    -Wno-everything

cp "$HERE/src/htmlsanitizer.mjs" "$OUT/" 2>/dev/null || true

say "built:"
ls -la "$OUT"/htmlsanitizer.wasm "$OUT"/htmlsanitizer.js | awk '{printf "    %-28s %8d bytes\n", $NF, $5}'
