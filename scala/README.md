# htmlsanitizer — Scala

Cleans HTML of constructs that can lead to XSS.

This layer is **idiomatic sugar only**. It carries no sanitizer logic *and no
FFI*: it compiles against the Java binding (`java/`, FFM / Panama) and reaches
the pure-Aether engine in `core/htmlsanitizer.ae` through it, by ordinary JVM
interop.

That is deliberate. There is exactly **one** FFI per runtime in this monorepo,
and on the JVM it is `java/src/main/java/org/htmlsanitizer`. A Scala-specific
FFI would be a second copy of the ABI's marshalling and ownership rules to keep
in step with `core/embed.ae` — and the first thing to drift. Kotlin, Scala,
Clojure and Groovy are all thin layers over the same Java classes.

## Requirements

* **JDK 22 or newer** — the FFM API the Java binding uses is final in 22, so
  `--enable-preview` is *not* needed, but `--enable-native-access=ALL-UNNAMED`
  is.
* **Scala 2.13.12+ or Scala 3.3+**, running on that JDK. One source file
  compiles under both — no `enum`, no `given`, no `extension`, just an implicit
  class and a sealed ADT. (2.12 would additionally need
  `scala-collection-compat` for `scala.jdk.CollectionConverters` and
  `IterableOnce`; this layer deliberately takes no such dependency.)

## Use

```scala
import org.htmlsanitizer.scala.HtmlSanitizers
import org.htmlsanitizer.scala.HtmlSanitizers._

HtmlSanitizers.withSanitizer() { s =>
  s.allowedTags += "my-widget"
  s.setKeepChildNodes(true)

  println(s.sanitize("""<div onclick="alert(1)">Hello</div>"""))
  // -> <div>Hello</div>

  // Relative URLs resolve against a base.
  s.sanitize("""<img src="logo.png">""", "https://example.com")
}
```

`withSanitizer` is the loan pattern: it always closes the sanitizer, releasing
the native handle and the upcall stubs, even if the body throws. It is called
that rather than `using` because **`using` is a keyword in Scala 3** —
`using()(body)` parses as a using-clause and does not compile.

There is also `sanitizer()` when the sanitizer must outlive one expression (the
caller then owns it and must `close()` it), and a one-shot:

```scala
val clean = HtmlSanitizers.sanitize("""<div onclick="alert(1)">Hello</div>""")
```

`HtmlSanitizer` is **not thread-safe** — the engine calls hooks re-entrantly
during `sanitize`.

## What Scala adds

**Flags.** Readers are no-paren accessors; writers are named `setX`:

```scala
s.keepChildNodes            // read
s.setKeepChildNodes(true)   // write
s.allowDataAttributes
s.setAllowDataAttributes(true)
```

The writers are *not* spelled `s.keepChildNodes = true`. Assignment syntax does
not work through an implicit/extension class — Scala 3 rejects it as
"Reassignment to val \<none\>", because there is no real field to assign.
Naming them honestly beats shipping a form that only looks like it works.

**Allow-lists.** Six live views — `allowedTags`, `allowedAttributes`,
`allowedCssProperties`, `allowedSchemes`, `allowedClasses`, `uriAttributes`.
They are views on the engine, not copies:

```scala
s.allowedTags += "my-widget"              // allow
s.allowedTags -= "script"                 // deny
s.allowedTags ++= List("b", "i")          // bulk allow
s.allowedTags --= List("b", "i")          // bulk deny
s.allowedTags.contains("div")             // query
s.allowedSchemes.size()                   // live count
s.allowedSchemes.toScalaList.sorted       // snapshot
s.allowedTags.replaceWith("b", "i")       // start from nothing
```

**Callbacks as plain function values.** Each returns the sanitizer, so they
chain.

```scala
// Returning true from a keep*If handler CANCELS the removal — it KEEPS the thing.
s.keepTagIf { (node, reason) => node.name() == "keep-me" }
s.keepAttributeIf { (elem, attr, reason) => false }
s.keepStyleIf { (elem, name, value, reason) => name == "-custom-thing" }
s.keepCommentIf(_ => true)

s.eachNode { node => /* ... */ }
s.eachDocument { doc => /* ... */ }

// Return the URL to use; an empty string DROPS the attribute.
s.rewriteUrls { (_, _, resolved) => resolved.replace("example.com", "cdn.example.net") }
```

They are named `keep*If` rather than `onRemoving*` for two reasons: the ABI's
rule is "non-zero **cancels** the removal", so the Java event names read as
though returning true would remove the thing — the opposite of the truth; and
distinct names sidestep overload ambiguity with the Java SAM methods.

**ADTs over the ABI's ints**

```scala
node.nodeKind        // NodeKind.Document / Element / Text / Comment
reason               // RemovalReason.NotAllowedTag, ...
```

Both are sealed with an `Unknown(code)` case, so a newer engine adding a
constant cannot make this layer throw — the ABI's constants are append-only, and
a total match over a closed set would be a latent break.

**DOM navigation**

```scala
elem.attribute("onclick").map(_.value())   // Option[String]
node.childNodes                            // List[Node]
node.attributeList                         // List[Attribute]
doc.walk                                   // depth-first List[Node], inclusive
```

`Node` and `Attribute` are **borrowed** views — the DOM is freed when
`sanitize` returns, so do not retain them past the callback. `walk` is a strict
`List`, not a `LazyList`, precisely so a lazy walk cannot be forced after the
DOM is gone.

## Tests

```
aeb scala/.tests.ae
```

or directly:

```
HS_JAVA_CLASSES=../target/.aeb/java-classes \
HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so \
  ./run-tests.sh
```

The suite is a plain main method, not ScalaTest or MUnit — same reason as the
Java binding's: it must run with nothing but a JDK and a Scala compiler, so it
works offline and cannot fail resolving a test-framework artifact.

It mirrors the 12 checks in `docs/conformance.md` and adds the remaining
callback shapes, plus checks specific to this layer (that `sanitizer()` closes
the handle when `configure` throws, that `withSanitizer` closes when the body
throws, that unknown ABI codes degrade to `Unknown` rather than throwing).

## Toolchain

`scala/.tests.ae` **skips** rather than failing if no usable Scala compiler is
present, printing `scala: skipped: ...`. "Usable" is a stronger condition than
"on PATH": scalac reads the Java binding's class files, which are JDK 22+
bytecode (the FFM API does not exist before 22), so an older scalac fails with a
class-file-version error that looks like a binding bug but is not.

`run-tests.sh` probes candidates and **verifies each by compiling a one-liner
against the real Java classes** before committing to it:

1. `$SCALA_JARS` — a directory holding a Scala 3 compiler and its dependencies
   (`scala3-compiler`, `scala3-library`, `scala3-interfaces`, `tasty-core`,
   `scala-library`, `scala-asm`, `compiler-interface`, `util-interface`). This is
   the no-install escape hatch, and it is checked first so it can override a
   broken system `scalac`.
2. `scalac` on `PATH` — used only if it survives the probe
3. Coursier's `cs launch scala3-compiler:3.3.4`, if `cs` is already installed
   (this script never installs anything itself)

If none works, the script exits 77 and the aeb node reports a skip. It does not
report a pass.

```
SCALA_JARS=/path/to/scala3-jars aeb scala/.tests.ae
```

## Engine resolution

Inherited from the Java binding:

1. an explicit path — `HtmlSanitizers.withSanitizer(Some("/path/to/lib.so"))`
2. `$HTMLSANITIZER_LIB`, then the `htmlsanitizer.lib` system property
3. `native/` beside the jar
4. the OS loader's own search path
