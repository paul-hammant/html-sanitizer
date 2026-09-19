#!/usr/bin/env bash
# Cut a GitHub Release for a tag and attach the cross-built sanitizer core
# artifacts + their checksums. Manual, CLI-only — no GitHub Actions, no repo
# settings, no secrets: it uses your existing `gh` auth to create the release
# and upload assets. (Registry publishing — PyPI/npm/Maven/… — is deliberately
# NOT here; that would need per-registry credentials.)
#
# Usage:
#   release/publish.sh v1.2.3               # build (if needed) + create the release
#   release/publish.sh v1.2.3 --draft       # create as a draft to review first
#   release/publish.sh v1.2.3 --no-build    # use whatever is already in release/dist
#
# Steps: ensure artifacts for <tag> exist (build them unless --no-build), then
# `gh release create <tag>` with every artifact, its .sha256, and SHA256SUMS.txt.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/release/dist"
cd "$ROOT"

die() { printf 'publish: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

TAG=""; NO_BUILD=0; GH_FLAGS=()
for a in "$@"; do
  case "$a" in
    --no-build)   NO_BUILD=1 ;;
    --draft)      GH_FLAGS+=(--draft) ;;
    --prerelease) GH_FLAGS+=(--prerelease) ;;
    -*)           die "unknown flag: $a" ;;
    *)            [ -z "$TAG" ] && TAG="$a" || die "unexpected arg: $a" ;;
  esac
done
[ -n "$TAG" ] || die "usage: release/publish.sh <tag> [--draft] [--prerelease] [--no-build]"
case "$TAG" in v*) ;; *) die "tag should look like vX.Y.Z (got '$TAG')" ;; esac

have gh || die "gh (GitHub CLI) not found — install it, or upload release/dist/* by hand"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run 'gh auth login'"

# One release serves both consumers of this repo: source consumers who clone at
# the tag, and FFI consumers who fetch the prebuilt libhtmlsanitizer.* assets
# built HERE. So the tag and the binaries must be the SAME code. Refuse to build
# from a dirty TRACKED tree (untracked scratch is fine) — otherwise the two could
# diverge.
COMMIT="$(git rev-parse HEAD)"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  die "working tree has uncommitted TRACKED changes — commit or stash them so the
       tag ($TAG @ ${COMMIT:0:9}) and the built binaries are the same code
       (untracked files are fine; 'git status' shows what's dirty)"
fi

# Build the matrix for this tag unless told to reuse dist.
if [ "$NO_BUILD" = "0" ]; then
  printf 'publish: building artifacts for %s …\n' "$TAG"
  RELEASE_TAG="$TAG" "$HERE/build.sh" || die "build failed — fix it, or --no-build to publish existing dist"
fi

# Collect what to upload: every artifact, its sidecar, and the manifest.
# nullglob makes an unmatched glob expand to nothing (not a literal).
shopt -s nullglob
bins=( "$DIST"/*.so "$DIST"/*.dylib "$DIST"/*.dll "$DIST"/*.dll.lib )
wasm=( "$DIST"/*.wasm "$DIST"/*.mjs )   # the browser/DOM target, if built
sums=( "$DIST"/*.sha256 )
manifest=( "$DIST"/SHA256SUMS.txt )
shopt -u nullglob
[ "${#bins[@]}" -gt 0 ] || die "no artifacts in release/dist — run release/build.sh (or drop --no-build)"
assets=( "${bins[@]}" "${wasm[@]}" "${sums[@]}" "${manifest[@]}" )

# Count only the loadable libraries (not the Windows .dll.lib import stubs).
nbin=0; for f in "${bins[@]}"; do case "$f" in *.dll.lib) ;; *) nbin=$((nbin+1)) ;; esac; done
# The os-arch combinations present, derived from the actual libs in dist.
plats="$(
  for f in "${bins[@]}"; do
    case "$f" in *.dll.lib) continue ;; esac
    b="$(basename "$f")"; echo "${b#libhtmlsanitizer-"$TAG"-}" | sed 's/\.[^.]*$//'
  done | sort -u | paste -sd', ' -
)"

# Note whether a wasm artifact is present, for the release notes.
wasm_note=""
[ "${#wasm[@]}" -gt 0 ] && wasm_note="

Also included: **wasm32-wasi** — the same sanitizer core recompiled to
WebAssembly (\`htmlsanitizer-$TAG-wasm32-wasi.wasm\` + its \`.mjs\` loader), so a
browser cleans HTML with byte-for-byte the same logic as the native libs."

NOTES="$(cat <<EOF
Prebuilt \`libhtmlsanitizer\` — the shared sanitizer core, cross-built from one
Linux host via \`ae build --target\` (zig cc). $nbin native platform artifact(s): $plats.

Each language binding \`dlopen\`s / links one of these by its C ABI. Verify a
download against its \`.sha256\` sidecar (or \`SHA256SUMS.txt\`) before use.

The sanitizer core is a pure string->string transform — no network, no
filesystem, no OS access — so every artifact is fully functional on its target
with no platform caveats.$wasm_note

Tag $TAG @ ${COMMIT:0:9}.
EOF
)"

printf 'publish: creating release %s with %d asset(s) …\n' "$TAG" "${#assets[@]}"
gh release create "$TAG" "${GH_FLAGS[@]}" \
  --title "$TAG" --notes "$NOTES" \
  "${assets[@]}" || die "gh release create failed"

printf 'publish: done — %s published with %d platform lib(s): %s\n' "$TAG" "$nbin" "$plats"
