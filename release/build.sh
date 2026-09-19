#!/usr/bin/env bash
# Cross-build the sanitizer core (libhtmlsanitizer) for the release matrix from
# ONE host, and emit each artifact with a .sha256 — ready for a GitHub release
# that the FFI bindings fetch by checksum.
#
# The sanitizer core is pure Aether; `ae build --target=<triple>` cross-compiles
# via zig cc, no per-OS runner. Output name:
# libhtmlsanitizer-<tag>-<os>-<arch>.<ext> (.so linux / .dylib macos / .dll
# windows). Alongside each: <artifact>.sha256, and a combined
# release/dist/SHA256SUMS.txt.
#
# Usage:
#   release/build.sh                    # core matrix (linux+macos x86_64/arm64)
#   RELEASE_EXTRA_TARGETS=1 release/build.sh   # + windows (slow) + freebsd (needs sysroot)
#   RELEASE_TAG=v1.2.3 release/build.sh  # stamp the tag into artifact names
#                                          (default: HTMLSANITIZER_VERSION, else
#                                           `git describe`, else "dev")
#   TARGETS="aarch64-macos" release/build.sh   # override the matrix entirely
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
. "$HERE/targets.env"
cd "$ROOT"

export PATH="${PREFIX:-$HOME/.local}/bin:$HOME/.aether/bin:$PATH"

say()  { printf 'release: %s\n' "$*"; }
die()  { printf 'release: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have ae || die "ae not on PATH (run ./bootstrap.sh or ci install first)"
have zig || die "zig not on PATH — required for cross-compilation (ae build --target)"
have sha256sum || die "sha256sum required to checksum artifacts"

# Tag precedence: RELEASE_TAG env > HTMLSANITIZER_VERSION file > git describe > dev.
if [ -n "${RELEASE_TAG:-}" ]; then
  TAG="$RELEASE_TAG"
elif [ -f "$ROOT/HTMLSANITIZER_VERSION" ]; then
  TAG="$(tr -d '[:space:]' < "$ROOT/HTMLSANITIZER_VERSION")"
else
  TAG="$(git describe --tags --always 2>/dev/null || echo dev)"
fi

# Resolve the matrix.
if [ -n "${TARGETS:-}" ]; then
  MATRIX="$TARGETS"
else
  MATRIX="$RELEASE_TARGETS"
  [ "${RELEASE_EXTRA_TARGETS:-0}" = "1" ] && MATRIX="$MATRIX $RELEASE_EXTRA_TARGETS_LIST"
fi

DIST="$ROOT/release/dist"
rm -rf "$DIST"; mkdir -p "$DIST"

# triple -> {os, arch, extension} for the artifact name.
os_of()  { case "$1" in *-linux|*-linux-musl) echo linux;; *-macos) echo macos;; *-windows) echo windows;; *-freebsd) echo freebsd;; *) echo unknown;; esac; }
arch_of(){ case "$1" in aarch64-*) echo arm64;; x86_64-*) echo x86_64;; *) echo "$1";; esac; }
ext_of() { case "$1" in *-macos) echo dylib;; *-windows) echo dll;; *) echo so;; esac; }

say "sanitizer core: libhtmlsanitizer  tag: $TAG"
say "matrix: $MATRIX"
echo

built=0; failed=0
for t in $MATRIX; do
  os=$(os_of "$t"); arch=$(arch_of "$t"); ext=$(ext_of "$t")
  name="libhtmlsanitizer-${TAG}-${os}-${arch}.${ext}"
  out="$DIST/$name"
  log="$DIST/.$t.log"

  # FreeBSD needs a base sysroot; skip loudly rather than fail if it's absent.
  if [ "$os" = "freebsd" ] && [ -z "${AETHER_SYSROOT:-}" ]; then
    say "SKIP $t — set AETHER_SYSROOT to a FreeBSD base sysroot"
    continue
  fi

  printf 'release:   %-18s -> %s ... ' "$t" "$name"
  # No --with / --lib: the sanitizer core is a pure string->string transform
  # with zero third-party deps (core/.build.ae). --size strips + size-optimizes.
  # --extra takes an ABSOLUTE path: ae >= 0.638's cross path (--target) no longer
  # resolves a relative --extra C file from CWD, so pass the absolute path.
  if ( cd "$ROOT/core" \
       && ae build --emit=lib --size --target="$t" \
            embed.ae --extra "$ROOT/core/_embed_support.c" -o "$out" ) >"$log" 2>&1; then
    ( cd "$DIST" && sha256sum "$name" > "$name.sha256" )
    # Windows emits an import library (<dll>.lib) beside the DLL — needed only by
    # a consumer that LINKS the DLL at build time (our FFI bindings dlopen at
    # runtime and don't need it, but ship + checksum it so Windows is first-class).
    if [ "$os" = "windows" ] && [ -f "$out.lib" ]; then
      ( cd "$DIST" && sha256sum "$name.lib" > "$name.lib.sha256" )
    fi
    printf 'ok  (%s)\n' "$(file -b "$out" 2>/dev/null | cut -c1-42)"
    built=$((built+1))
    rm -f "$log"
  else
    printf 'FAILED\n'
    sed 's/^/release:     /' "$log" | grep -iE 'error|fatal' | head -3
    failed=$((failed+1))
  fi
done

# A combined checksum manifest over every artifact (not the .sha256 sidecars).
# Named SHA256SUMS.txt so a browser renders it inline (no forced download).
( cd "$DIST" && sha256sum ./*.so ./*.dylib ./*.dll ./*.dll.lib 2>/dev/null > SHA256SUMS.txt || true )

echo
say "built $built artifact(s) into release/dist/ ($failed failed)"
if [ "$built" -gt 0 ]; then
  echo
  ( cd "$DIST" && for f in *.so *.dylib *.dll; do [ -f "$f" ] && printf '  %s…  %s\n' "$(cut -c1-16 "$f.sha256")" "$f"; done ) 2>/dev/null
  echo
  say "each artifact has a .sha256; SHA256SUMS.txt lists them all."
  say "next: release/publish.sh <tag> to cut a GitHub release with these attached."
fi
[ "$failed" -eq 0 ] || exit 1
