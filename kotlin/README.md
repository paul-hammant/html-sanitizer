# htmlsanitizer — Kotlin

Cleans HTML of constructs that can lead to XSS.

This layer is **idiomatic sugar only**. It carries no sanitizer logic *and no
FFI*: it compiles against the Java binding (`java/`, FFM / Panama) and reaches
the pure-Aether engine in `core/htmlsanitizer.ae` through it, by ordinary JVM
interop.

That is deliberate. There is exactly **one** FFI per runtime in this monorepo,
and on the JVM it is `java/src/main/java/org/htmlsanitizer`. A Kotlin-specific
FFI would be a second copy of the ABI's marshalling and ownership rules to keep
in step with `core/embed.ae` — and the first thing to drift. Kotlin, Scala,
Clojure and Groovy are all thin layers over the same Java classes.

## Requirements

* **JDK 22 or newer** — the FFM API the Java binding uses is final in 22, so
  `--enable-preview` is *not* needed, but `--enable-native-access=ALL-UNNAMED`
  is.
* **Kotlin 1.9 or newer** (2.x tested). Older compilers cannot read the Java
  binding's class files at all — see [Toolchain](#toolchain) below.

## Use

```kotlin
import org.htmlsanitizer.kotlin.*

htmlSanitizer {
    allowedTags += "my-widget"
    keepChildNodes = true
}.use { s ->
    println(s.sanitize("""<div onclick="alert(1)">Hello</div>"""))
    // -> <div>Hello</div>

    // Relative URLs resolve against a base.
    s.sanitize("""<img src="logo.png">""", "https://example.com")
}
```

`HtmlSanitizer` is `AutoCloseable`, so `use` releases the native handle and the
upcall stubs. It is **not thread-safe** — the engine calls hooks re-entrantly
during `sanitize`.

For the one-expression case there is `sanitizing`, which constructs, runs and
closes:

```kotlin
val clean = sanitizing { it.sanitize("<div>x</div>") }
```

## What Kotlin adds

Everything below is sugar over the Java API, which remains available and
unchanged.

**Flags as properties**

```kotlin
s.keepChildNodes = true
s.allowDataAttributes = true
```

**Allow-lists as collections.** Six live views — `allowedTags`,
`allowedAttributes`, `allowedCssProperties`, `allowedSchemes`, `allowedClasses`,
`uriAttributes`. They are views on the engine, not copies:

```kotlin
s.allowedTags += "my-widget"          // allow
s.allowedTags -= "script"             // deny
s.allowedTags += listOf("b", "i")     // bulk
"div" in s.allowedTags                // query
s.allowedSchemes.count                // live count, straight from the engine
s.allowedSchemes.sorted()             // AllowList is Iterable<String>
s.allowedTags.replaceWith("b", "i")   // start from nothing
```

Use `.count`, not `.size`: `size` would collide with the Java `size()` member,
and Kotlin's `Iterable.count()` would snapshot the entire list just to measure
it.

**Callbacks as trailing lambdas.** Each returns the sanitizer, so they chain.

```kotlin
// Returning true from a keep*If handler CANCELS the removal — it KEEPS the thing.
s.keepTagIf { node, reason -> node.name() == "keep-me" }
s.keepAttributeIf { elem, attr, reason -> false }
s.keepStyleIf { elem, name, value, reason -> name == "-custom-thing" }
s.keepCommentIf { node -> true }

s.eachNode { node -> /* ... */ }
s.eachDocument { doc -> /* ... */ }

// Rewrite a URL; an empty string drops the attribute.
s.rewriteUrls { _, _, resolved -> resolved.replace("example.com", "cdn.example.net") }
```

These are named `keepTagIf` rather than `onRemovingTag` for a reason that bites
if ignored: in Kotlin a **member always wins over an extension of the same
name**, so an extension called `onRemovingTag` would be silently unreachable —
every call site would bind to the Java method and the enum conversion would
never run. The `keep*If` naming also states which way the boolean goes, which
the ABI's "non-zero cancels the removal" does not make obvious.

The Java hooks (`onRemovingTag` and friends) still work directly and give you
the ABI's bare `Int` reason.

**Enums over the ABI's ints**

```kotlin
node.nodeKind                    // NodeKind.DOCUMENT / ELEMENT / TEXT / COMMENT
reason                           // RemovalReason.NOT_ALLOWED_TAG, ...
```

Both have an `UNKNOWN` member, so a newer engine adding a constant cannot make
this layer throw — the ABI's constants are append-only.

**DOM sugar**

```kotlin
elem["onclick"]?.value()         // attribute by name, or null
doc.walk()                       // depth-first Sequence<Node>, inclusive
```

`Node` and `Attribute` are **borrowed** views — the DOM is freed when
`sanitize` returns, so do not retain them past the callback. `walk()` is a
`Sequence`, so consume it inside the callback too.

## Tests

```
aeb kotlin/.tests.ae
```

or directly:

```
HS_JAVA_CLASSES=../target/.aeb/java-classes \
HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so \
  ./run-tests.sh
```

The suite is a plain main method, not JUnit — same reason as the Java binding's:
it must run with nothing but a JDK and a Kotlin compiler, so it works offline
and cannot fail resolving a test-framework artifact.

It mirrors the 12 checks in `docs/conformance.md` and adds the remaining
callback shapes, plus a few checks specific to this layer (that the builder
applies its configuration, that it closes the handle when `configure` throws,
that `+=` mutates the live view rather than a copy).

## Toolchain

`kotlin/.tests.ae` **skips** rather than failing if no usable Kotlin compiler is
present, printing `kotlin: skipped: ...`. "Usable" is a stronger condition than
"on PATH":

The Java binding is compiled by a JDK 22+ `javac`, because the FFM API does not
exist before 22. Its class files are therefore major version 66+. A Kotlin
compiler bundles its own ASM to read Java class files, and anything older than
roughly 1.9 rejects those outright with `Unsupported class file major version`.
Debian's `kotlinc` package is 1.3 and fails exactly that way — it also only runs
under JDK 17 or older itself.

So `run-tests.sh` does not trust `command -v kotlinc`. It probes candidates in
order and **verifies each by compiling a one-liner against the real Java
classes** before committing to it:

1. `$KOTLIN_COMPILER_JAR`, if you point it at a `kotlin-compiler-embeddable` jar
2. a `kotlin-compiler-embeddable` jar found in a Gradle distribution or `~/.m2`
   (Gradle ships 2.x, which needs no separate install)
3. `kotlinc` on `PATH` — used only if it survives the probe

If none works, the script exits 77 and the aeb node reports a skip. It does not
report a pass.

## Engine resolution

Inherited from the Java binding:

1. an explicit path — `htmlSanitizer("/path/to/libhtmlsanitizer.so")`
2. `$HTMLSANITIZER_LIB`, then the `htmlsanitizer.lib` system property
3. `native/` beside the jar
4. the OS loader's own search path
