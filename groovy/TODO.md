# Groovy layer — TODO

## Migrate `run-tests.sh` → aeb's `groovy` SDK (probe + SKIP now upstream)

**Context.** `groovy/.tests.ae` currently `os.system(...)`s a hand-written
`run-tests.sh` because aeb's `groovy` SDK couldn't do the two things this suite
needs: (1) *verify* a Groovy-4-on-JDK-22 toolchain by probe (the Java binding is
JDK-22+ bytecode, so Debian's groovy 2.4 on JDK 17 neither reads nor runs it),
and (2) SKIP cleanly when none is present instead of a false pass/fail. It also
runs a custom `ConformanceTest` main, not a JUnit5 suite.

**That gap is now closed in aeb** (lib/build + lib/groovy). The SDK gained:

- `min_groovy(4)` / `min_jdk(22)` — resolves a groovyc+JVM by **verifying a
  candidate** (compile+run a probe against this node's real dep classpath),
  newest-capable-first from `$GROOVY_JAR` / `$GROOVY_HOME` / `~/.m2` / gradle
  dists. Exactly what `run-tests.sh`'s `try_groovy_cp` does — now in the SDK.
- **SKIP as a first-class outcome** — when no capable toolchain qualifies, the
  node reports *skipped* (green, skip-counted in telemetry), not failed. This
  replaces the `exit 77` convention; no magic exit code needed.
- `main_class("...")` + `jvm_flag("...")` — run a custom (non-JUnit5) runner on
  the verified JVM with extra JVM flags.

Proven end-to-end on a box with the exact trap (PATH groovy 2.4 on JDK 17) and
escape (groovy-4.0.24 in `~/.m2`, JDK 24): the SDK rejects 2.4, selects 4.0.24
on JDK 24, compiles, and runs the runner — and SKIPs green when the minimum is
raised out of reach.

### What to do

Rewrite `groovy/.tests.ae` to use the SDK, and **delete `run-tests.sh`**:

```
import build
import groovy
import groovy (source_layout, min_groovy, min_jdk, main_class, jvm_flag)

aeb(cap) {
    b = build.start()
    build.dep(b, "core/.build.ae")
    build.dep(b, "java/.build.ae")
    groovy.groovyc_test(b) {
        source_layout("maven idiomatic")
        min_groovy(4)
        min_jdk(22)
        main_class("org.htmlsanitizer.groovy.ConformanceTest")
        jvm_flag("--enable-native-access=ALL-UNNAMED")
    }
}
```

The `build.dep`s give the compile+run classpath (java classes, and the sanitizer core
`.so` the java binding dlopens); the SDK puts the verified groovy jar,
`test-classes/`, and the dep classpath on the run classpath automatically.

### Verify parity before deleting the script

`run-tests.sh` does three things the SDK path must still cover — confirm each on
a machine WITH a capable toolchain before removing the script:

1. **The `HTMLSANITIZER_LIB` env var** the java binding reads to find the sanitizer core
   `.so`. The SDK doesn't set app-specific env; if the java-binding dep artifact
   doesn't already export the `.so` location onto the runner's environment,
   thread it via a `jvm_flag("-Dhtmlsanitizer.lib=...")` or an env the runner
   reads — check how `java/.tests` runs the same suite and mirror it.
2. **The META-INF extension descriptor.** `run-tests.sh` copies
   `src/main/resources/META-INF` next to the compiled classes so the operator
   overloads (`<<`, `-`, `[]`, `.text`) register; without it the DSL compiles
   but the extension methods silently don't exist at run time. The SDK's
   `groovyc_test` compiles test sources but does **not** yet stage
   `src/main/resources/META-INF` onto the run classpath — verify the descriptor
   is visible to `main_class`, and if not, either add a resources() step to the
   SDK (preferred, file upstream) or keep a thin copy step for now.
3. **The bytecode-mismatch reject.** The script greps the compile log for
   `UnsupportedClassVersionError` / `class file version`; the SDK's
   `build._verify_toolchain` does the same veto. No action — just don't
   reintroduce a probe that only checks compile-succeeds.

If any of (1)/(2) can't be expressed through the SDK yet, that's an aeb ask, not
a reason to keep the bespoke script — file it against aeb `lib/groovy` and we'll
close it the same way we closed the probe/SKIP gap.

### Cross-refs

- aeb `lib/groovy`: `min_groovy` / `min_jdk` / `main_class` / `jvm_flag`,
  `_resolve_capable_groovy` (the probe).
- aeb `lib/build`: `_verify_toolchain(probe, ok_token)`, `_record_skip(ctx, reason)`
  — shared JVM-toolchain primitives; kotlin/scala/clojure can adopt them too.
