# aeb: a java.javac node's classpath artifact grows by one entry on every re-run in the same target/

For aeb (found with aeb v0.347 and v0.348, Aether 0.931.0, Linux x86_64).

## What goes wrong

The artifact `jvm_classpath_deps_including_transitive` a `java.javac()` node
publishes is rewritten on every run of that node, and each run appends one more
copy of the node's own classes directory when it is run again in the same
`target/` (a cache miss on the node is enough; the sources do not change). The
file should be one line, the classes directory (plus its dependencies' lines).

After runs 1 to 4 of the same node the file holds:

    run 1:  <root>/target/build/lib/classes
    run 2:  <root>/target/build/lib/classes
            <root>/target/build/lib/classes:<root>/target/build/lib/classes
    run 3:  the same, and the second line now has three colon-joined copies
    run 4:  the second line has four

(The first line is the classes dir; the second line is a colon-joined list
that gains one copy per further run.) A consumer that takes the
artifact as one classpath (`kotlinc -cp "$classes"`, `java -cp "$classes:..."`)
gets an embedded newline: kotlinc then reports `unresolved reference` for every
class of the Java binding. In html-sanitizer this made `kotlin/.tests.ae` fail
once the java node had been built earlier in the same `target/`; the scala,
clojure and groovy `run-tests.sh` scripts and the java and kotlin `.tests.ae`
now turn newlines into colons, which hides the symptom, not the growth.

## Minimal repro (no html-sanitizer needed)

    mkdir -p javarepro/lib/src/main/java/demo && cd javarepro && touch .aeb
    cat > lib/src/main/java/demo/Hello.java <<'JAVA'
    package demo;
    public class Hello { public static String hi() { return "hi"; } }
    JAVA
    cat > lib/.build.ae <<'AE'
    import bldr
    import java
    import java (source_layout)

    aeb(cap) {
        bldr.build() {
            java.javac() {
                source_layout("maven idiomatic")
            }
        }
    }
    AE
    for i in 1 2 3 4; do
        aeb lib/.build.ae
        echo "after run $i:"
        cat -A target/build/lib/jvm_classpath_deps_including_transitive
        echo
    done

Observed (v0.348, ae 0.931.0, cachyos): one line after run 1, then a second
line `classes:classes` after run 2, `classes:classes:classes` after run 3, and so
on. Expected: the same single line every time.

## Where to look

`lib/java/module.ae` at v0.348, the block just before
`bldr._write_artifact(ctx, "jvm_classpath_deps_including_transitive", cp_out)`
(about line 1288 to 1306). It appends `own_cp` ("this node's OWN
jar_pinned/jar_vendored jars"). My guess, not confirmed: `own_cp` is read back
from the node's own artifact left by the previous run, so it carries the
previous classes dir (and its previous `own_cp`) forward. The artifact should
be rebuilt from this run's inputs only, or `own_cp` must be reset per run.

Not fixed here: this is aeb's to fix. html-sanitizer only works around the
symptom in its own run scripts.
