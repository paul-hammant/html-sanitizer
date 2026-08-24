# Scala layer — TODO

## Migrate `run-tests.sh` → aeb's `scala` SDK (shared probe/SKIP primitives now upstream)

**Context.** `scala/.tests.ae` shells out to `run-tests.sh` because it needs
what a plain `scalac` invocation can't give: (1) *verify* a Scala-that-can-read-
JDK-22-bytecode toolchain by probe (the Java binding is JDK-22+ bytecode; an old
scalac fails with a class-file-version error that looks like a binding bug), (2)
SKIP (exit 77) when none is present rather than a false pass/fail, and (3) run a
custom `org.htmlsanitizer.scala.ConformanceTest` main with
`--enable-native-access=ALL-UNNAMED`.

**The reusable half is now in aeb.** Two language-agnostic primitives landed in
`lib/build`, and were proven end-to-end via the Groovy SDK on a real box:

- `build._verify_toolchain(probe_cmd, ok_token)` — the "present vs. actually
  usable" gate. The probe must PRINT a success token (os.exec doesn't surface
  exit codes), and a bytecode-version marker (`class file version` /
  `Unsupported class file`) in the output vetoes the candidate. This is exactly
  `run-tests.sh`'s "compile a Probe.scala, then commit" logic.
- `build._record_skip(ctx, reason)` — marks the node *skipped* (green,
  skip-counted in telemetry), replacing the `exit 77` convention.

**LANDED (committed + pushed).** `lib/scala` gained **`min_jdk(22)` + a
`main_class` run step** on `scalac_test`: it selects a JDK ≥ 22 for compile+run,
SKIPs (green) if none, and runs `main_class` on that JVM with `jvm_flag(...)`.
The SDK already resolves a capable Scala 3 compiler via `aeb-resolve`, so —
unlike the first draft of this note — **no `min_scala`/compiler-probe was
needed**: only the JVM floor and the run step were missing, and that's what
landed. (`scalac_test` was compile-only before; it now runs `main_class` too.)

### Rewrite `scala/.tests.ae`

```
import build
import scala
import scala (min_jdk, main_class, jvm_flag)

aeb(cap) {
    b = build.start()
    build.dep(b, "core/.build.ae")
    build.dep(b, "java/.build.ae")
    scala.scalac_test(b) {
        min_jdk(22)
        main_class("org.htmlsanitizer.scala.ConformanceTest")
        jvm_flag("--enable-native-access=ALL-UNNAMED")
    }
}
```

**Step 3:** on a machine WITH a capable toolchain, confirm parity, then
**delete `run-tests.sh`**.

### Verify parity before deleting the script

`run-tests.sh` does things the SDK path must still cover — confirm each first:

1. **`HTMLSANITIZER_LIB`** — the engine `.so` the java binding dlopens. Ensure
   it reaches the runner's environment (mirror how `java/.tests` does it, or a
   `jvm_flag`/env the runner reads).
2. **The scala-library on the RUN classpath.** `run-tests.sh` deliberately runs
   the JVM directly (not the `scala` launcher) so it can add
   `--enable-native-access` — and therefore has to put `scala-library` /
   `scala3-library` on the classpath itself (`find_scala_libs`). The SDK's
   `main_class` run must do the same; verify the library jars from the verified
   compiler classpath are on the run `-cp`, or `object ConformanceTest` won't
   load.
3. **The bytecode-version veto** — covered by `build._verify_toolchain`; don't
   reintroduce a probe that only checks "compile succeeded".

If any can't be expressed through the SDK yet, that's an aeb ask against
`lib/scala`, not a reason to keep the bespoke script.

### Cross-refs

- aeb `lib/build`: `_verify_toolchain(probe, ok_token)`, `_record_skip(ctx, reason)`
  — shared JVM-toolchain primitives (added with the Groovy migration; kotlin +
  scala adopt them next).
- aeb `lib/groovy`: the reference implementation of `min_*` + probe + SKIP +
  `main_class` this SDK should mirror.
- Sibling notes: `groovy/TODO.md`, `kotlin/TODO.md` — same shape, same three
  parity items (env `.so`, runtime library jars, bytecode veto).
