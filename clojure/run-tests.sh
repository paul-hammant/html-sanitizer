#!/usr/bin/env sh
# Compile-free run of the Clojure conformance suite.
#
# Inputs (set by clojure/.tests.ae; all have sensible defaults for a manual run):
#   HS_JAVA_CLASSES    the Java binding's compiled classes (java/.build.ae artifact)
#   HTMLSANITIZER_LIB  the sanitizer core .so                      (core/.build.ae artifact)
#
# Exit codes: 0 pass, 1 fail, 77 = no usable Clojure toolchain (SKIP).
#
# ---------------------------------------------------------------------------
# Clojure needs no AOT step here — clojure.main loads the namespaces from source
# — so the only requirement is a Clojure runtime jar on a JDK 22+ VM. The JDK
# floor is not negotiable: the Java binding's classes are 22+ bytecode because
# the FFM API does not exist before 22, and the Clojure runtime has to LOAD
# them, not merely compile against them.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")

HS_JAVA_CLASSES=${HS_JAVA_CLASSES:-"$root/target/.aeb/java-classes"}
HTMLSANITIZER_LIB=${HTMLSANITIZER_LIB:-"$root/core/native/libhtmlsanitizer.so"}
export HTMLSANITIZER_LIB

if [ ! -d "$HS_JAVA_CLASSES" ]; then
    echo "clojure: the Java binding classes are missing ($HS_JAVA_CLASSES)." >&2
    echo "clojure: run \`aeb java/.build.ae\` first, or use \`aeb clojure/.tests.ae\`." >&2
    exit 1
fi

# ---- a JVM new enough to RUN the FFM binding ----
find_run_java() {
    for cand in \
        "${JAVA_HOME:-}/bin/java" \
        /usr/lib/jvm/java-24-*/bin/java \
        /usr/lib/jvm/java-23-*/bin/java \
        /usr/lib/jvm/java-22-*/bin/java \
        "$(command -v java 2>/dev/null || true)"
    do
        [ -x "$cand" ] || continue
        v=$("$cand" -XshowSettings:properties -version 2>&1 \
            | sed -n 's/.*java\.specification\.version = \([0-9][0-9]*\).*/\1/p' | head -1)
        [ -n "$v" ] || continue
        [ "$v" -ge 22 ] 2>/dev/null || continue
        echo "$cand"
        return 0
    done
    return 1
}

RUN_JAVA=$(find_run_java || true)
if [ -z "$RUN_JAVA" ]; then
    echo "clojure: skipped: no JDK 22+ to run the FFM binding on"
    exit 77
fi

# ---- find a Clojure runtime ----
#
# Candidates:
#   1. $CLOJURE_JARS — a directory of clojure/spec.alpha/core.specs.alpha jars.
#      The no-install escape hatch, checked first.
#   2. the `clojure` / `clj` CLI, which brings its own runtime
#   3. clojure jars already in ~/.m2 or the Gradle caches

CLJ_CP=""

if [ -n "${CLOJURE_JARS:-}" ] && [ -d "$CLOJURE_JARS" ]; then
    c=$(ls "$CLOJURE_JARS"/*.jar 2>/dev/null | tr '\n' ':')
    [ -n "$c" ] && CLJ_CP=$c
fi

if [ -z "$CLJ_CP" ]; then
    # clojure-<ver>.jar plus its two spec dependencies; without spec.alpha the
    # runtime fails to boot, so all three have to be found together.
    cj=$( { ls "$HOME"/.m2/repository/org/clojure/clojure/*/clojure-*.jar \
                "$HOME"/.gradle/caches/modules-2/files-2.1/org.clojure/clojure/*/*/clojure-*.jar \
                2>/dev/null || true; } | grep -v sources | sort -Vr | head -1)
    if [ -n "$cj" ]; then
        sa=$( { ls "$HOME"/.m2/repository/org/clojure/spec.alpha/*/spec.alpha-*.jar \
                    "$HOME"/.gradle/caches/modules-2/files-2.1/org.clojure/spec.alpha/*/*/spec.alpha-*.jar \
                    2>/dev/null || true; } | grep -v sources | sort -Vr | head -1)
        cs=$( { ls "$HOME"/.m2/repository/org/clojure/core.specs.alpha/*/core.specs.alpha-*.jar \
                    "$HOME"/.gradle/caches/modules-2/files-2.1/org.clojure/core.specs.alpha/*/*/core.specs.alpha-*.jar \
                    2>/dev/null || true; } | grep -v sources | sort -Vr | head -1)
        if [ -n "$sa" ] && [ -n "$cs" ]; then
            CLJ_CP="$cj:$sa:$cs:"
        fi
    fi
fi

SRC="$here/src:$here/test"

if [ -n "$CLJ_CP" ]; then
    exec "$RUN_JAVA" --enable-native-access=ALL-UNNAMED \
        -cp "${CLJ_CP}${HS_JAVA_CLASSES}:$SRC" \
        clojure.main -m org.htmlsanitizer.conformance-test
fi

# 2. the Clojure CLI. It manages its own classpath, so we hand it ours with
#    -Scp and let it supply the runtime.
#    NB: "a binary named clojure is on PATH" is NOT enough. Debian ships a
#    /usr/bin/clojure that is a DIFFERENT tool — it does not understand
#    -Sdescribe/-Scp and dies with "-Scp (No such file or directory)", which
#    reads as a test failure rather than a missing toolchain. Verify with
#    -Sdescribe (cheap, read-only) before trusting it.
cli=""
for c in clojure clj; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -Sdescribe >/dev/null 2>&1; then
        cli=$(command -v "$c")
        break
    fi
done
if [ -n "$cli" ]; then
    # JAVA_OPTS is how the CLI passes flags to the JVM it launches.
    JAVA_HOME=$(dirname "$(dirname "$RUN_JAVA")") \
    JAVA_OPTS="--enable-native-access=ALL-UNNAMED" \
        exec "$cli" -Scp "$HS_JAVA_CLASSES:$SRC" \
        -M -m org.htmlsanitizer.conformance-test
fi

echo "clojure: skipped: clojure not installed"
echo "clojure:   install the Clojure CLI, or set CLOJURE_JARS to a directory holding"
echo "clojure:   clojure-<ver>.jar, spec.alpha-<ver>.jar and core.specs.alpha-<ver>.jar,"
echo "clojure:   then re-run."
exit 77
