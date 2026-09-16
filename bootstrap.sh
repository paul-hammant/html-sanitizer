#!/usr/bin/env bash
# One-command casual-dev bootstrap for the html-sanitizer monorepo.
#
# Ensures the Aether toolchain (`ae`) and the build runner (`aeb`) are present,
# then builds the native sanitizer engine and every binding whose language
# toolchain is actually installed on this box.
#
# The toolchains install via aeb's canonical remote installer, get.sh, which
# ensures BOTH `ae` and `aeb` binary-first (no compiler, no make — aeb >=
# v0.298). It works from a bare clone (no sibling checkouts), installs released
# builds to a user prefix, and runs no tests:
#     aeb get.sh: https://raw.githubusercontent.com/aether-lang-dev/aeb/main/get.sh
#
# Installing the toolchain needs only `curl`. BUILDING THE ENGINE additionally
# needs a C compiler (Aether compiles to C) — checked below, before the build.
#
# Idempotent: a no-op for the toolchain when `ae`/`aeb` are already good.
#
# The known-good pins live in ci/versions.env (AETHER_REF, AEB_REF); this reads
# them so there is one place to bump. Override at the shell to test a bump.
#
# Env overrides:
#   PREFIX        install prefix                 (default: $HOME/.local; no sudo)
#   AETHER_REF    ae tag/branch/SHA to install   (default: ci/versions.env) — pin in CI
#   AEB_REF       aeb tag/branch/SHA to install  (default: ci/versions.env) — pin in CI
#   MIN_AE        minimum acceptable ae version  (default: ci/versions.env floor)
# Extra args pass through to `aeb` (e.g. ./bootstrap.sh core/.build.ae).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"; export PREFIX
AEB_GET_URL="https://raw.githubusercontent.com/aether-lang-dev/aeb/main/get.sh"

# Pins from ci/versions.env (shell-overridable). AETHER_REF vX.Y.Z -> AE_PIN X.Y.Z.
# shellcheck disable=SC1091
[ -f "$HERE/ci/versions.env" ] && . "$HERE/ci/versions.env"
MIN_AE="${MIN_AE:-${AETHER_REF#v}}"; MIN_AE="${MIN_AE:-0.677.0}"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
ae_version() { ae --version 2>/dev/null | head -n1 | sed -E 's/^ae ([0-9]+\.[0-9]+\.[0-9]+).*/\1/'; }

export PATH="$PREFIX/bin:$PATH"   # so freshly-installed ae/aeb are found below

# ---- 1. Toolchain (ae + aeb), via aeb's get.sh (binary-first, make-free) ----
# Downloaded to a file and run under bash. get.sh also supports `curl … | sh`
# directly; downloading first just surfaces a fetch error and shows progress.
if command -v ae >/dev/null 2>&1 && command -v aeb >/dev/null 2>&1 \
   && have="$(ae_version || true)" && [ -n "$have" ] && version_ge "$have" "$MIN_AE"; then
    say "ae $have + aeb already on PATH (ae >= $MIN_AE) — skipping toolchain install"
else
    command -v curl >/dev/null 2>&1 || die "curl is required to install the Aether toolchain (or install ae/aeb yourself and re-run)."
    say "installing ae + aeb via get.sh (AE_PIN=${MIN_AE}, AEB_REF=${AEB_REF:-latest}, PREFIX=$PREFIX)"
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    curl -fsSL "$AEB_GET_URL" -o "$tmp" || die "could not download get.sh"
    AE_PIN="${MIN_AE}" AEB_REF="${AEB_REF:-}" PREFIX="$PREFIX" bash "$tmp" || die "toolchain install failed (get.sh)."
    command -v ae  >/dev/null 2>&1 || die "ae installed but not on PATH — ensure $PREFIX/bin is on PATH."
    command -v aeb >/dev/null 2>&1 || die "aeb installed but not on PATH — ensure $PREFIX/bin is on PATH."
    say "ae $(ae_version) + aeb ready"
fi

# ---- 2. Preflight for BUILDING the engine: a C compiler ----
# Aether compiles to C and hands off to a C compiler. The toolchain install
# above needs none, but core/.build.ae does. Check before the build so a
# missing compiler fails clearly HERE, not cryptically inside `ae build`.
command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 \
    || die "a C compiler (cc/gcc/clang) is required to build the engine — Aether compiles to C. Install e.g. build-essential (Debian/Ubuntu) or the Xcode Command Line Tools (macOS)."

# ---- 3. Build ----
cd "$HERE"
case ":$PATH:" in *":$PREFIX/bin:"*) : ;; *) say "tip: add '$PREFIX/bin' to your shell PATH permanently";; esac

# With explicit args, honor them verbatim. Otherwise build the engine (which
# needs only `ae` + a C compiler, both ensured above) plus the leaves whose
# toolchain is present. Each binding leaf also skips itself gracefully when its
# toolchain is missing, so this sniff is belt-and-braces — it keeps the run
# short rather than being load-bearing for correctness.
if [ "$#" -gt 0 ]; then
    targets="$*"
else
    targets="core/.build.ae core_tests/.tests.ae core_tests/.abi.ae"
    skipped=""
    while read -r cmd leaf; do
        [ -n "$cmd" ] || continue
        if command -v "$cmd" >/dev/null 2>&1; then
            targets="$targets $leaf"
        else
            skipped="$skipped ${leaf%%/*}(no $cmd)"
        fi
    done <<'TOOLCHAINS'
python3  python/.tests.ae
ruby     ruby/.tests.ae
go       go/.tests.ae
cargo    rust/.tests.ae
javac    java/.tests.ae
node     javascript/.tests.ae
dotnet   dotnet/.tests.ae
dart     dart/.tests.ae
php      php/.tests.ae
lua5.4   lua/.tests.ae
ghc      haskell/.tests.ae
nim      nim/.tests.ae
zig      zig/.tests.ae
erl      erlang/.tests.ae
elixir   elixir/.tests.ae
gleam    gleam/.tests.ae
kotlinc  kotlin/.tests.ae
scalac   scala/.tests.ae
clojure  clojure/.tests.ae
groovy   groovy/.tests.ae
pharo    pharo/.tests.ae
TOOLCHAINS
    [ -n "$skipped" ] && say "skipping (toolchain absent):$skipped"
fi

# shellcheck disable=SC2086  # word-splitting the sniffed target list is intentional
say "aeb $targets"
aeb $targets   # aeb exits non-zero on a failed leaf (>= v0.287), so this gates.
say "done."
