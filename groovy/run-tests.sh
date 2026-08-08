#!/usr/bin/env sh
# Compile and run the Groovy conformance suite.
#
# Inputs (set by groovy/.tests.ae; all have sensible defaults for a manual run):
#   HS_JAVA_CLASSES    the Java binding's compiled classes (java/.build.ae artifact)
#   HS_OUT             where to put the compiled Groovy classes
#   HTMLSANITIZER_LIB  the engine .so                      (core/.build.ae artifact)
#
# Exit codes: 0 pass, 1 fail, 77 = no usable Groovy toolchain (SKIP).
#
# ---------------------------------------------------------------------------
# Why this is not just `groovyc`
#
# The Java binding is compiled by a JDK 22+ javac, because the FFM API it binds
# through does not exist before 22 — so its class files are major version 66+.
# groovyc LOADS the classes it compiles against into its own JVM, so it fails on
# those unless it is BOTH new enough (Groovy 4+) and running on a JDK 22+ VM:
#
#     UnsupportedClassVersionError: ... class file version 68.0
#
# Debian's `groovy` package is 2.4 on JDK 17 and fails exactly that way. So
# "groovy is on PATH" is NOT the same question as "Groovy can build this", and
# testing the wrong one is how a suite ends up falsely skipped or falsely
# failed. We probe candidates and VERIFY the choice by compiling a one-liner
# against the real Java classes before committing to it.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")

HS_JAVA_CLASSES=${HS_JAVA_CLASSES:-"$root/target/.aeb/java-classes"}
HS_OUT=${HS_OUT:-"$root/target/.aeb/groovy-classes"}
HTMLSANITIZER_LIB=${HTMLSANITIZER_LIB:-"$root/core/native/libhtmlsanitizer.so"}
export HTMLSANITIZER_LIB

if [ ! -d "$HS_JAVA_CLASSES" ]; then
    echo "groovy: the Java binding classes are missing ($HS_JAVA_CLASSES)." >&2
    echo "groovy: run \`aeb java/.build.ae\` first, or use \`aeb groovy/.tests.ae\`." >&2
    exit 1
fi

# ---- a JVM new enough to RUN (and compile against) the FFM binding ----
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
    echo "groovy: skipped: no JDK 22+ to run the FFM binding on"
    exit 77
fi

# ---- find a Groovy jar that can read JDK 22+ bytecode ----
#
# Candidates, newest first:
#   1. $GROOVY_JAR, if the developer pointed us at one
#   2. $GROOVY_HOME/lib, or the lib dir of a `groovy` on PATH
#   3. a groovy-4.x jar from ~/.m2 or a Gradle distribution
#
# Groovy 4 renamed the coordinates to org.apache.groovy; a 4.x jar is what we
# want, and 3.x/2.x are rejected by the probe below anyway.

probe_dir=$(mktemp -d)
trap 'rm -rf "$probe_dir"' EXIT
# The probe both COMPILES against the real Java classes (which a Groovy too old
# to read JDK 22+ bytecode cannot do) and RUNS, exercising withCloseable — the
# Object extension method added in Groovy 4. Compiling alone is not enough:
# Groovy 3 compiles this binding happily and then dies at run time with
# MissingMethodException: HtmlSanitizer.withCloseable(). Probing only the
# compile is how you end up "passing" the toolchain check and failing the suite.
cat > "$probe_dir/Probe.groovy" <<'EOF'
import org.htmlsanitizer.HtmlSanitizer
class Probe {
    static void main(String[] args) {
        // Touches the FFM-bearing class AND the Groovy-4-only extension method.
        new HtmlSanitizer().withCloseable { HtmlSanitizer s ->
            assert s.sanitize('<div>x</div>') == '<div>x</div>'
        }
        println('probe-ok')
    }
}
EOF

GROOVY_CP=""

try_groovy_cp() {
    cp=$1
    [ -n "$cp" ] || return 1
    rm -rf "$probe_dir/out"
    mkdir -p "$probe_dir/out"
    "$RUN_JAVA" -cp "$cp" org.codehaus.groovy.tools.FileSystemCompiler \
        -cp "$HS_JAVA_CLASSES" -d "$probe_dir/out" "$probe_dir/Probe.groovy" \
        >"$probe_dir/log" 2>&1 || return 1
    # A too-old Groovy reports this rather than failing outright in some paths.
    grep -q 'UnsupportedClassVersionError\|class file version' "$probe_dir/log" && return 1
    "$RUN_JAVA" --enable-native-access=ALL-UNNAMED \
        -cp "$cp:$HS_JAVA_CLASSES:$probe_dir/out" Probe \
        >"$probe_dir/runlog" 2>&1 || return 1
    grep -q 'probe-ok' "$probe_dir/runlog" || return 1
    GROOVY_CP=$cp
    return 0
}

# Every candidate list below funnels through here. Two traps it avoids:
#
#  * `groovy-*.jar` also matches the SUB-ARTIFACTS (groovy-xml, groovy-json,
#    groovy-ant, ...), none of which contain the compiler. Only `groovy-<ver>.jar`
#    is the core jar, hence the version-anchored pattern.
#  * sorting FULL PATHS puts /home/.../gradle-9.0-.../groovy-3.0.24.jar above
#    /home/.../4.0.24/groovy-4.0.24.jar, because the comparison sees the
#    directory first. We sort on the extracted version instead, so the newest
#    Groovy wins wherever it happens to live.
#
# Getting this wrong is not harmless: Groovy 3 compiles this binding fine but
# has no Object.withCloseable, so the suite fails at RUN time with a
# MissingMethodException that looks like a binding bug rather than a
# toolchain-selection bug.
list_core_groovy_jars() {
    for d in "$@"; do
        [ -d "$d" ] || continue
        for j in "$d"/groovy-[0-9]*.jar; do
            [ -f "$j" ] || continue
            case $(basename "$j") in
                # groovy-<digits>... only — rejects groovy-xml-3.0.24.jar etc.
                groovy-[0-9]*) ;;
                *) continue ;;
            esac
            echo "$j"
        done
    done | grep -v sources | while read -r j; do
        v=$(basename "$j" .jar | sed 's/^groovy-//')
        printf '%s\t%s\n' "$v" "$j"
    done | sort -Vr | cut -f2
}

# Build a classpath from a lib directory holding groovy jars.
cp_from_libdir() {
    j=$(list_core_groovy_jars "$1" | head -1)
    [ -n "$j" ] || return 1
    echo "$j"
}

# 1. explicit override
if [ -n "${GROOVY_JAR:-}" ] && [ -f "$GROOVY_JAR" ]; then
    try_groovy_cp "$GROOVY_JAR" || true
fi

# 2. $GROOVY_HOME, or the groovy on PATH
if [ -z "$GROOVY_CP" ] && [ -n "${GROOVY_HOME:-}" ]; then
    c=$(cp_from_libdir "$GROOVY_HOME/lib" || true)
    [ -n "$c" ] && { try_groovy_cp "$c" || true; }
fi
if [ -z "$GROOVY_CP" ] && command -v groovy >/dev/null 2>&1; then
    gh=$(dirname "$(dirname "$(readlink -f "$(command -v groovy)")")")
    c=$(cp_from_libdir "$gh/lib" || true)
    [ -n "$c" ] && { try_groovy_cp "$c" || true; }
fi

# 3. a groovy jar from the local Maven repo or a Gradle distribution, newest
#    first (org.apache.groovy is the Groovy 4+ coordinate; org.codehaus.groovy
#    is 3.x and earlier, searched too so the probe can reject it explicitly).
if [ -z "$GROOVY_CP" ]; then
    for jar in $(list_core_groovy_jars \
            "$HOME"/.m2/repository/org/apache/groovy/groovy/* \
            "$HOME"/.m2/repository/org/codehaus/groovy/groovy/* \
            "$HOME"/.gradle/wrapper/dists/*/*/*/lib)
    do
        try_groovy_cp "$jar" && break
    done
fi

if [ -z "$GROOVY_CP" ]; then
    if command -v groovy >/dev/null 2>&1; then
        echo "groovy: skipped: groovy not installed at a version that can read JDK 22+ bytecode"
        echo "groovy:   (the groovy on PATH is too old — groovyc loads the Java binding's"
        echo "groovy:    classes, which are JDK 22+ because the FFM API requires it)"
    else
        echo "groovy: skipped: groovy not installed"
    fi
    echo "groovy:   install Groovy 4.x on a JDK 22+ VM, or set GROOVY_JAR to a"
    echo "groovy:   groovy-4.x jar, then re-run."
    exit 77
fi

# ---- compile ----
rm -rf "$HS_OUT"
mkdir -p "$HS_OUT"

sources=$(find "$here/src" -name '*.groovy' | sort)

# shellcheck disable=SC2086
"$RUN_JAVA" -cp "$GROOVY_CP" org.codehaus.groovy.tools.FileSystemCompiler \
    -cp "$HS_JAVA_CLASSES" -d "$HS_OUT" $sources

# The extension module descriptor has to be ON the classpath for the operators
# (<<, -, [], .text) to register; without it the DSL still works but the
# extension methods silently do not exist.
if [ -d "$here/src/main/resources/META-INF" ]; then
    cp -R "$here/src/main/resources/META-INF" "$HS_OUT/"
fi

# ---- run ----
# FFM is final in JDK 22, so --enable-preview is NOT needed; the native access
# flag is, and without it the JVM only warns today but will refuse later.
exec "$RUN_JAVA" --enable-native-access=ALL-UNNAMED \
    -cp "$GROOVY_CP:$HS_JAVA_CLASSES:$HS_OUT" org.htmlsanitizer.groovy.ConformanceTest
