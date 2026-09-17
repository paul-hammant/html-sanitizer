#!/usr/bin/env sh
# Compile and run the Scala conformance suite.
#
# Inputs (set by scala/.tests.ae; all have sensible defaults for a manual run):
#   HS_JAVA_CLASSES    the Java binding's compiled classes (java/.build.ae artifact)
#   HS_OUT             where to put the compiled Scala classes
#   HTMLSANITIZER_LIB  the sanitizer core .so                      (core/.build.ae artifact)
#
# Exit codes: 0 pass, 1 fail, 77 = no usable Scala toolchain (SKIP).
#
# ---------------------------------------------------------------------------
# Toolchain requirements, and why merely finding `scalac` is not enough
#
# The Java binding is compiled by a JDK 22+ javac, because the FFM API it binds
# through does not exist before 22 — so its class files are major version 66+.
# scalac reads those class files, so it has to be new enough to parse them
# (Scala 2.13.12+ / Scala 3.3+ in practice) and be running on a JDK 22+ VM.
# An older scalac fails with a class-file-version error that looks like a
# binding bug but is not.
#
# So we probe: find a candidate, then VERIFY it by compiling a one-liner against
# the real Java classes before committing to it. If nothing works we exit 77 and
# the aeb node reports a SKIP — never a false pass.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")

HS_JAVA_CLASSES=${HS_JAVA_CLASSES:-"$root/target/.aeb/java-classes"}
HS_OUT=${HS_OUT:-"$root/target/.aeb/scala-classes"}
HTMLSANITIZER_LIB=${HTMLSANITIZER_LIB:-"$root/core/native/libhtmlsanitizer.so"}
export HTMLSANITIZER_LIB

if [ ! -d "$HS_JAVA_CLASSES" ]; then
    echo "scala: the Java binding classes are missing ($HS_JAVA_CLASSES)." >&2
    echo "scala: run \`aeb java/.build.ae\` first, or use \`aeb scala/.tests.ae\`." >&2
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
    echo "scala: skipped: no JDK 22+ to run the FFM binding on"
    exit 77
fi

probe_dir=$(mktemp -d)
trap 'rm -rf "$probe_dir"' EXIT
cat > "$probe_dir/Probe.scala" <<'EOF'
import org.htmlsanitizer.HtmlSanitizer
object Probe { def n: Int = classOf[HtmlSanitizer].getName.length }
EOF

SCALAC=""     # a command prefix that behaves like scalac
SCALA_LIB=""  # scala-library (and, for Scala 3, scala3-library) for the run
SCALA_JARS_CP=""   # set when we drive dotc from a directory of jars

# 1. $SCALA_JARS — a directory holding a Scala 3 compiler and its dependencies
#    (scala3-compiler, scala3-library, scala3-interfaces, tasty-core,
#    scala-library, scala-asm, compiler-interface, util-interface). This is the
#    no-install escape hatch: drop the jars in a directory, point SCALA_JARS at
#    it, and the suite runs. Checked first so it can override a broken system
#    scalac.
if [ -n "${SCALA_JARS:-}" ] && [ -d "$SCALA_JARS" ]; then
    cp_jars=$(ls "$SCALA_JARS"/*.jar 2>/dev/null | tr '\n' ':')
    if [ -n "$cp_jars" ]; then
        # scalac/dotc requires -d to name an EXISTING directory (or a .jar);
        # it does not create one, and the error it gives if you forget looks
        # like a "compiler not usable" result rather than a typo.
        mkdir -p "$probe_dir/out0"
        if "$RUN_JAVA" -cp "$cp_jars" dotty.tools.dotc.Main \
                -classpath "$cp_jars$HS_JAVA_CLASSES" \
                -d "$probe_dir/out0" "$probe_dir/Probe.scala" \
                >"$probe_dir/log0" 2>&1; then
            SCALAC="dotc-jars"
            SCALA_JARS_CP=$cp_jars
        fi
    fi
fi

# 2. scalac on PATH — probed, not assumed.
if [ -z "$SCALAC" ] && command -v scalac >/dev/null 2>&1; then
    mkdir -p "$probe_dir/out"
    if scalac -classpath "$HS_JAVA_CLASSES" -d "$probe_dir/out" "$probe_dir/Probe.scala" \
            >"$probe_dir/log" 2>&1; then
        SCALAC="scalac"
    fi
fi

# 3. Coursier can fetch and run a compiler without a system install. Only used
#    if it is already present — this script never installs anything.
if [ -z "$SCALAC" ] && command -v cs >/dev/null 2>&1; then
    mkdir -p "$probe_dir/out2"
    if cs launch scala3-compiler:3.3.4 -- -classpath "$HS_JAVA_CLASSES" \
            -d "$probe_dir/out2" "$probe_dir/Probe.scala" >"$probe_dir/log2" 2>&1; then
        SCALAC="cs launch scala3-compiler:3.3.4 --"
    fi
fi

if [ -z "$SCALAC" ]; then
    if command -v scalac >/dev/null 2>&1; then
        echo "scala: skipped: scalac not installed at a version that can read JDK 22+ bytecode"
        echo "scala:   (the scalac on PATH cannot parse the Java binding's class files,"
        echo "scala:    which are JDK 22+ because the FFM API requires it)"
    else
        echo "scala: skipped: scalac not installed"
    fi
    echo "scala:   install Scala 2.13.12+ or 3.3+ on a JDK 22+ VM (or Coursier's \`cs\`),"
    echo "scala:   or set SCALA_JARS to a directory of Scala 3 compiler jars, then re-run."
    exit 77
fi

# ---- compile ----
rm -rf "$HS_OUT"
mkdir -p "$HS_OUT"

sources=$(find "$here/src" -name '*.scala' | sort)

if [ "$SCALAC" = "dotc-jars" ]; then
    # shellcheck disable=SC2086
    "$RUN_JAVA" -cp "$SCALA_JARS_CP" dotty.tools.dotc.Main \
        -classpath "$SCALA_JARS_CP$HS_JAVA_CLASSES" -d "$HS_OUT" $sources
else
    # shellcheck disable=SC2086
    $SCALAC -classpath "$HS_JAVA_CLASSES" -d "$HS_OUT" $sources
fi

# ---- work out the Scala library jars needed at run time ----
#
# `scala` the runner would supply these, but it is not always installed next to
# scalac, and we need to add --enable-native-access anyway — so we run the JVM
# directly and put the library jars on the classpath ourselves.
find_scala_libs() {
    if [ -n "$SCALA_JARS_CP" ]; then
        # Already a full compiler+library classpath; reuse it wholesale.
        echo "$SCALA_JARS_CP"
        return
    fi
    if command -v scalac >/dev/null 2>&1; then
        sc=$(readlink -f "$(command -v scalac)")
        libdir=$(dirname "$(dirname "$sc")")/lib
        if [ -d "$libdir" ]; then
            ls "$libdir"/scala-library*.jar "$libdir"/scala3-library*.jar 2>/dev/null \
                | tr '\n' ':'
            return
        fi
    fi
    # Coursier's cache, or a local Maven repo.
    { ls "$HOME"/.cache/coursier/v1/https/*/org/scala-lang/scala3-library_3/*/scala3-library_3-*.jar \
         "$HOME"/.cache/coursier/v1/https/*/org/scala-lang/scala-library/*/scala-library-*.jar \
         "$HOME"/.m2/repository/org/scala-lang/scala-library/*/scala-library-*.jar \
         2>/dev/null || true; } | grep -v sources | sort -Vr | head -2 | tr '\n' ':'
}

SCALA_LIB=$(find_scala_libs)
if [ -z "$SCALA_LIB" ]; then
    echo "scala: skipped: compiled, but no scala-library jar found to run against"
    exit 77
fi

# ---- run ----
# FFM is final in JDK 22, so --enable-preview is NOT needed; the native access
# flag is, and without it the JVM only warns today but will refuse later.
exec "$RUN_JAVA" --enable-native-access=ALL-UNNAMED \
    -cp "${SCALA_LIB}${HS_JAVA_CLASSES}:$HS_OUT" org.htmlsanitizer.scala.ConformanceTest
