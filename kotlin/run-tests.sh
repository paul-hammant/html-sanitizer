#!/usr/bin/env sh
# Compile and run the Kotlin conformance suite.
#
# Inputs (set by kotlin/.tests.ae; all have sensible defaults for a manual run):
#   HS_JAVA_CLASSES  the Java binding's compiled classes  (java/.build.ae artifact)
#   HS_OUT           where to put the compiled Kotlin classes
#   HTMLSANITIZER_LIB  the engine .so                     (core/.build.ae artifact)
#
# Exit codes: 0 pass, 1 fail, 77 = no usable Kotlin toolchain (SKIP).
#
# ---------------------------------------------------------------------------
# Why this is not just `kotlinc`
#
# The Java binding is compiled by a JDK 22+ javac, because the FFM API it binds
# through does not exist before 22. That makes its class files major version 66
# or higher. A Kotlin compiler bundles its own ASM to read Java class files, and
# anything older than ~1.9 rejects major > 61 outright:
#
#     Unsupported class file major version 68
#
# Debian's `kotlinc` package is 1.3, which fails exactly that way — and it also
# only runs under JDK 17 or older itself. So "kotlinc is on PATH" is NOT the
# same question as "Kotlin can build this", and testing the wrong one is how a
# suite ends up either falsely skipped or falsely failed.
#
# We therefore probe for a capable compiler in preference order and, crucially,
# VERIFY the choice by compiling a one-liner against the real Java classes
# before committing to it.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")

HS_JAVA_CLASSES=${HS_JAVA_CLASSES:-"$root/target/.aeb/java-classes"}
HS_OUT=${HS_OUT:-"$root/target/.aeb/kotlin-classes"}
HTMLSANITIZER_LIB=${HTMLSANITIZER_LIB:-"$root/core/native/libhtmlsanitizer.so"}
export HTMLSANITIZER_LIB

if [ ! -d "$HS_JAVA_CLASSES" ]; then
    echo "kotlin: the Java binding classes are missing ($HS_JAVA_CLASSES)." >&2
    echo "kotlin: run \`aeb java/.build.ae\` first, or use \`aeb kotlin/.tests.ae\`." >&2
    exit 1
fi

# ---- a JVM new enough to RUN the FFM binding (22+) ----
#
# Separate question from which JDK the Kotlin compiler runs under: the compiler
# only has to emit classes, the test run has to actually call into FFM.
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
    echo "kotlin: skipped: no JDK 22+ to run the FFM binding on"
    exit 77
fi

# ---- find a Kotlin compiler that can read JDK 22+ bytecode ----
#
# Candidates, newest-capable first:
#   1. $KOTLIN_COMPILER_JAR / $KOTLIN_HOME, if the developer pointed us at one
#   2. a kotlin-compiler-embeddable jar from a Gradle distribution or ~/.m2
#      (Gradle ships 2.x, which is new enough and needs no install step)
#   3. `kotlinc` on PATH, but only if it actually survives the probe
#
# Each candidate is a shell command prefix that takes kotlinc arguments.

probe_src=$(mktemp -d)
trap 'rm -rf "$probe_src"' EXIT
cat > "$probe_src/Probe.kt" <<'EOF'
import org.htmlsanitizer.HtmlSanitizer
fun probeMain() { HtmlSanitizer::class.java.name.length }
EOF

# Try one embeddable compiler jar; echo a runnable command on success.
try_embeddable() {
    jar=$1
    libdir=$(dirname "$jar")
    stdlib=$(ls "$libdir"/kotlin-stdlib-*.jar 2>/dev/null | grep -v sources | head -1)
    [ -n "$stdlib" ] || return 1
    cp="$jar:$stdlib"
    for extra in kotlin-reflect kotlin-script-runtime trove4j annotations kotlinx-coroutines-core-jvm; do
        j=$(ls "$libdir"/$extra-*.jar 2>/dev/null | grep -v sources | head -1)
        [ -n "$j" ] && cp="$cp:$j"
    done
    # The compiler itself is a plain Java program; run it on the same JVM we
    # will run the tests on.
    "$RUN_JAVA" -cp "$cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
        -no-stdlib -nowarn -cp "$HS_JAVA_CLASSES:$stdlib" \
        -d "$probe_src/out" "$probe_src/Probe.kt" >"$probe_src/log" 2>&1 || return 1
    grep -q 'Unsupported class file' "$probe_src/log" && return 1
    KOTLINC_CP=$cp
    KOTLIN_STDLIB=$stdlib
    return 0
}

KOTLINC_CP=""
KOTLIN_STDLIB=""

# 1. explicit override
if [ -n "${KOTLIN_COMPILER_JAR:-}" ] && [ -f "$KOTLIN_COMPILER_JAR" ]; then
    try_embeddable "$KOTLIN_COMPILER_JAR" || true
fi

# 2. embeddable jars from Gradle distributions / the local Maven repo.
if [ -z "$KOTLINC_CP" ]; then
    for jar in $( { ls "$HOME"/.gradle/wrapper/dists/*/*/*/lib/kotlin-compiler-embeddable-*.jar \
                    "$HOME"/.m2/repository/org/jetbrains/kotlin/kotlin-compiler-embeddable/*/kotlin-compiler-embeddable-*.jar \
                    2>/dev/null || true; } | sort -Vr )
    do
        try_embeddable "$jar" && break
    done
fi

# 3. kotlinc on PATH — probed, not assumed.
KOTLINC_BIN=""
if [ -z "$KOTLINC_CP" ] && command -v kotlinc >/dev/null 2>&1; then
    if kotlinc -nowarn -cp "$HS_JAVA_CLASSES" -d "$probe_src/out2" "$probe_src/Probe.kt" \
            >"$probe_src/log2" 2>&1 && ! grep -q 'Unsupported class file' "$probe_src/log2"; then
        KOTLINC_BIN=kotlinc
    fi
fi

if [ -z "$KOTLINC_CP" ] && [ -z "$KOTLINC_BIN" ]; then
    # Say WHY, so this does not look like the suite simply not existing.
    if command -v kotlinc >/dev/null 2>&1; then
        echo "kotlin: skipped: kotlinc not installed at a version that can read JDK 22+ bytecode"
        echo "kotlin:   (the kotlinc on PATH is too old — it cannot parse the Java binding's"
        echo "kotlin:    class files, which are JDK 22+ because the FFM API requires it)"
    else
        echo "kotlin: skipped: kotlinc not installed"
    fi
    echo "kotlin:   install Kotlin 1.9+ / 2.x, or set KOTLIN_COMPILER_JAR to a"
    echo "kotlin:   kotlin-compiler-embeddable jar, then re-run."
    exit 77
fi

# ---- compile ----
rm -rf "$HS_OUT"
mkdir -p "$HS_OUT"

sources=$(find "$here/src" -name '*.kt' | sort)

if [ -n "$KOTLINC_CP" ]; then
    # shellcheck disable=SC2086
    "$RUN_JAVA" -cp "$KOTLINC_CP" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
        -no-stdlib -nowarn \
        -cp "$HS_JAVA_CLASSES:$KOTLIN_STDLIB" \
        -d "$HS_OUT" $sources
    RUN_CP="$KOTLIN_STDLIB:$HS_JAVA_CLASSES:$HS_OUT"
else
    # shellcheck disable=SC2086
    $KOTLINC_BIN -nowarn -cp "$HS_JAVA_CLASSES" -d "$HS_OUT" $sources
    # kotlinc's own stdlib, so the run can find it.
    kt_home=$(dirname "$(dirname "$(readlink -f "$(command -v kotlinc)")")")
    stdlib=$(ls "$kt_home"/lib/kotlin-stdlib.jar 2>/dev/null | head -1)
    RUN_CP="${stdlib:-}:$HS_JAVA_CLASSES:$HS_OUT"
fi

# ---- run ----
# FFM is final in JDK 22, so --enable-preview is NOT needed; the native access
# flag is, and without it the JVM only warns today but will refuse later.
exec "$RUN_JAVA" --enable-native-access=ALL-UNNAMED \
    -cp "$RUN_CP" org.htmlsanitizer.kotlin.ConformanceTest
