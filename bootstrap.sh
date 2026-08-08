#!/usr/bin/env bash
# One-command casual-dev bootstrap for the html-sanitizer monorepo.
#
# Ensures the Aether toolchain (`ae`) and the build runner (`aeb`) are present,
# then builds the native sanitizer engine and every binding whose language
# toolchain is actually installed on this box.
#
# The toolchains are installed via their canonical remote installers — they
# work from a bare clone (no sibling checkouts), install released builds to a
# user prefix, run no tests:
#     aether: https://raw.githubusercontent.com/aether-lang-dev/aether/main/get.sh
#     aeb:    https://raw.githubusercontent.com/aether-lang-dev/aeb/main/install.sh
#
# Idempotent: a no-op for the toolchain when `ae`/`aeb` are already good.
# Requires `curl` to install them; no build-from-source fallback.
#
# Env overrides:
#   PREFIX        install prefix                 (default: $HOME/.local; no sudo)
#   AETHER_REF    ae tag/branch/SHA to install   (default: latest tag) — pin in CI
#   AEB_REF       aeb tag/branch/SHA to install  (default: latest tag) — pin in CI
#   MIN_AE        minimum acceptable ae version  (default: 0.183.0)
# Extra args pass through to `aeb` (e.g. ./bootstrap.sh core/.build.ae).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"; export PREFIX
MIN_AE="${MIN_AE:-0.183.0}"
AETHER_GET_URL="https://raw.githubusercontent.com/aether-lang-dev/aether/main/get.sh"
AEB_INSTALL_URL="https://raw.githubusercontent.com/aether-lang-dev/aeb/main/install.sh"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
ae_version() { ae --version 2>/dev/null | head -n1 | sed -E 's/^ae ([0-9]+\.[0-9]+\.[0-9]+).*/\1/'; }

# fetch_run URL : download an installer to a temp file and run it under sh,
# inheriting the (exported) env the caller set. Avoids `curl | sh` masking a
# fetch failure.
fetch_run() {
    command -v curl >/dev/null 2>&1 || die "curl is required to install the Aether toolchain (or install ae/aeb yourself and re-run)."
    local tmp rc; tmp="$(mktemp)"
    if curl -fsSL "$1" -o "$tmp"; then sh "$tmp"; rc=$?; else rc=$?; fi
    rm -f "$tmp"; return $rc
}

export PATH="$PREFIX/bin:$PATH"   # so freshly-installed ae/aeb are found below

# ---- 0. Preflight: a C compiler + make ----
# Aether compiles to C and hands off to a C compiler; the source-tarball
# installers for ae/aeb also need make + cc. Check up front so a missing
# compiler fails clearly HERE, not cryptically later inside `ae build`.
command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 \
    || die "a C compiler (cc/gcc/clang) is required — Aether compiles to C. Install e.g. build-essential (Debian/Ubuntu) or the Xcode Command Line Tools (macOS)."
command -v make >/dev/null 2>&1 \
    || die "GNU make is required to build the Aether toolchain from source. Install e.g. build-essential / make."

# ---- 1. Aether toolchain (ae) ----
if command -v ae >/dev/null 2>&1 && have="$(ae_version || true)" && [ -n "$have" ] && version_ge "$have" "$MIN_AE"; then
    say "ae $have already on PATH (>= $MIN_AE) — skipping"
else
    say "installing ae via get.sh (AETHER_REF=${AETHER_REF:-latest}, PREFIX=$PREFIX)"
    AETHER_REF="${AETHER_REF:-}" fetch_run "$AETHER_GET_URL" || die "ae install failed (get.sh)."
    command -v ae >/dev/null 2>&1 || die "ae installed but not on PATH — ensure $PREFIX/bin is on PATH."
    say "ae $(ae_version) ready"
fi

# ---- 2. Build runner (aeb) ----
if command -v aeb >/dev/null 2>&1; then
    say "aeb already on PATH — skipping"
else
    say "installing aeb via install.sh (AEB_REF=${AEB_REF:-latest}, PREFIX=$PREFIX)"
    AEB_REF="${AEB_REF:-}" AETHER="$(command -v ae)" fetch_run "$AEB_INSTALL_URL" || die "aeb install failed (install.sh)."
    command -v aeb >/dev/null 2>&1 || die "aeb installed but not on PATH — ensure $PREFIX/bin is on PATH."
fi
say "using aeb: $(command -v aeb)"

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
aeb $targets || true

# aeb currently exits 0 even when a leaf fails, so its status is not a usable
# gate. Read the per-node logs instead — every leaf here ends with an explicit
# PASS / SKIPPED / failure line.
say "verdicts (from target/.aeb/logs/):"
rc=0
for f in target/.aeb/logs/*.log; do
    [ -e "$f" ] || continue
    label="$(basename "$f" .log)"
    line="$(grep -E 'PASS|SKIPPED|built|failed|FAIL' "$f" | tail -1)"
    case "$line" in
        *SKIPPED*) printf '  \033[1;33mskip\033[0m  %-22s %s\n' "$label" "$line" ;;
        *PASS*|*built*) printf '  \033[1;32mok\033[0m    %-22s %s\n' "$label" "$line" ;;
        *) printf '  \033[1;31mFAIL\033[0m  %-22s %s\n' "$label" "$line"; rc=1 ;;
    esac
done

if [ "$rc" -ne 0 ]; then
    cat >&2 <<EOF

At least one node failed. Common causes:
  - A '--emit=lib ... recompile with -fPIC' link error means a stale ae.
    Reinstall a current one:  AETHER_REF=v0.184.0 $0
  - A binding's toolchain is present but too old (e.g. a kotlinc/groovy that
    cannot read the JDK 22+ bytecode the Java binding needs), or a test runner
    is missing (pytest, rspec).
    Build a known-good subset:  $0 core/.build.ae core_tests/.abi.ae
EOF
    exit 1
fi
say "done."
