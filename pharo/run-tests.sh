#!/usr/bin/env sh
# Load the HtmlSanitizer package into a throwaway Pharo image and run SUnit
# headless.
#
# Inputs (set by pharo/.tests.ae; both have sensible defaults for a manual run):
#   HTMLSANITIZER_LIB  the sanitizer core .so  (core/.build.ae artifact)
#   PHARO_DIR          where the Pharo VM + image live (default ~/.local/pharo)
#
# Exit codes: 0 pass, 1 fail, 77 = no Pharo VM (SKIP).
#
# ---------------------------------------------------------------------------
# Unlike the Kotlin/Scala/Clojure/Groovy layers, which are thin wrappers over
# the Java binding, the Pharo binding is a REAL FFI (UnifiedFFI) — Pharo is not
# a JVM. So there is no Java classpath here at all, only the sanitizer core .so.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")

HTMLSANITIZER_LIB=${HTMLSANITIZER_LIB:-"$root/core/native/libhtmlsanitizer.so"}
export HTMLSANITIZER_LIB

PHARO_DIR=${PHARO_DIR:-"$HOME/.local/pharo"}

# ---- find a Pharo VM ----
#
# Either `pharo` on PATH or a $PHARO_DIR holding the usual VM layout. Nothing
# is downloaded here: a test runner that installs a VM behind your back is a
# worse failure mode than a clear skip.
PHARO_BIN=""
if command -v pharo >/dev/null 2>&1; then
    PHARO_BIN=$(command -v pharo)
elif [ -x "$PHARO_DIR/pharo" ]; then
    PHARO_BIN="$PHARO_DIR/pharo"
elif [ -x "$PHARO_DIR/pharo-vm/Pharo" ]; then
    PHARO_BIN="$PHARO_DIR/pharo-vm/Pharo"
fi

if [ -z "$PHARO_BIN" ]; then
    echo "pharo: skipped: pharo not installed"
    echo "pharo:   install a Pharo VM + image, e.g."
    echo "pharo:     mkdir -p \"$PHARO_DIR\" && cd \"$PHARO_DIR\" &&"
    echo "pharo:     curl -L https://get.pharo.org/64/110+vm | bash"
    echo "pharo:   then re-run (or set PHARO_DIR)."
    exit 77
fi

# ---- find an image ----
IMAGE=""
for cand in "$PHARO_DIR"/*.image "$here"/*.image; do
    [ -f "$cand" ] && { IMAGE=$cand; break; }
done

if [ -z "$IMAGE" ]; then
    echo "pharo: skipped: a Pharo VM was found but no .image in $PHARO_DIR"
    echo "pharo:   fetch one with: cd \"$PHARO_DIR\" && curl -L https://get.pharo.org/64/110 | bash"
    exit 77
fi

# ---- work on a COPY of the image ----
#
# Loading code mutates a Pharo image permanently. Running against the
# developer's own image would leave this package (and any load failure) baked
# into it, so we always work on a throwaway.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$IMAGE" "$work/HtmlSanitizer.image"
base=$(dirname "$IMAGE")/$(basename "$IMAGE" .image)
[ -f "$base.changes" ] && cp "$base.changes" "$work/HtmlSanitizer.changes"
for src in "$base.sources" "$(dirname "$IMAGE")"/*.sources; do
    [ -f "$src" ] && cp "$src" "$work/" 2>/dev/null || true
done

# ---- load the package from Tonel and run the suite ----
#
# `metacello ... repository: 'tonel://...'` reads the sources straight from the
# working tree, so the tests always run against what is checked out — no
# intermediate artifact to go stale.
cat > "$work/load.st" <<EOF
[
    Metacello new
        baseline: 'HtmlSanitizer';
        repository: 'tonel://$here/src';
        load.
] on: Error do: [ :e |
    Transcript show: 'pharo: failed to load the package: ', e messageText; cr.
    Smalltalk exitFailure ].
Smalltalk snapshot: true andQuit: true.
EOF

# Run from $work, not from the source tree. A Pharo test run drops
# PharoDebug.log, progress.log and a .fuel file per non-passing test into the
# CURRENT directory — checking those into pharo/ would be pure litter, and
# `$work` is removed on exit anyway.
cd "$work"

"$PHARO_BIN" --headless "$work/HtmlSanitizer.image" st --quit "$work/load.st" \
    || { echo "pharo: package load failed"; exit 1; }

# `test` exits non-zero if any test fails, which is what we key off.
"$PHARO_BIN" --headless "$work/HtmlSanitizer.image" test --junit-xml-output HtmlSanitizer
rc=$?

if [ $rc -eq 0 ]; then
    echo "pharo: conformance suite passed"
fi
exit $rc
