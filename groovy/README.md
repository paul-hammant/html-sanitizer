# htmlsanitizer — Groovy

Cleans HTML of constructs that can lead to XSS.

This layer is **idiomatic sugar only**. It carries no sanitizer logic *and no
FFI*: it compiles against the Java binding (`java/`, FFM / Panama) and reaches
the pure-Aether engine in `core/htmlsanitizer.ae` through it, by ordinary JVM
interop.

That is deliberate. There is exactly **one** FFI per runtime in this monorepo,
and on the JVM it is `java/src/main/java/org/htmlsanitizer`. A Groovy-specific
FFI would be a second copy of the ABI's marshalling and ownership rules to keep
in step with `core/embed.ae` — and the first thing to drift. Kotlin, Scala,
Clojure and Groovy are all thin layers over the same Java classes.

## Requirements

* **JDK 22 or newer** — the FFM API the Java binding uses is final in 22, so
  `--enable-preview` is *not* needed, but `--enable-native-access=ALL-UNNAMED`
  is.
* **Groovy 4 or newer, running on that JDK.** Groovy 3 and earlier cannot be
  used — see [Toolchain](#toolchain).

## Use

```groovy
import static org.htmlsanitizer.groovy.HtmlSanitizers.htmlSanitizer

htmlSanitizer {
    allowTags 'my-widget'
    keepChildNodes = true
    keepTagIf { node, reason -> node.name() == 'keep-me' }
}.withCloseable { s ->
    println s.sanitize('<div onclick="alert(1)">Hello</div>')
    // -> <div>Hello</div>

    // Relative URLs resolve against a base.
    s.sanitize('<img src="logo.png">', 'https://example.com')
}
```

`HtmlSanitizer` is `AutoCloseable`, so `withCloseable` releases the native
handle and the upcall stubs. It is **not thread-safe** — the engine calls hooks
re-entrantly during `sanitize`.

Shorthands for the one-expression cases:

```groovy
// construct, use, close
def clean = HtmlSanitizers.sanitizing(null, null) { s -> s.sanitize('<div>x</div>') }

// secure defaults, one fragment
def clean2 = HtmlSanitizers.sanitize('<div onclick="alert(1)">Hello</div>')
```

## The DSL

Inside a `htmlSanitizer { }` block the delegate is a `SanitizerSpec`, so these
verbs can be written bare. Everything mutates the live engine — nothing is
buffered, so ordering in the block is the ordering the engine sees.

**Flags**

```groovy
keepChildNodes = true
allowDataAttributes = true
```

**Allow-lists**

```groovy
allowTags 'my-widget', 'my-other-widget'
denyTags 'script'
allowAttributes 'data-id'
denyAttributes 'style'
allowCssProperties 'color'
allowSchemes 'mailto'
allowClasses 'highlight'
uriAttributes 'ping'
```

The six live views are also reachable — `allowedTags`, `allowedAttributes`,
`allowedCssProperties`, `allowedSchemes`, `allowedClasses`, `uriAttributes` —
for anything the verbs do not cover.

**Callbacks.** Returning **true KEEPS** the thing (the ABI's rule is "non-zero
cancels the removal"); the `keep*If` naming is what makes that direction
unmissable.

```groovy
keepTagIf       { node, reason -> node.name() == 'keep-me' }
keepAttributeIf { elem, attr, reason -> attr.name() == 'data-id' }
keepStyleIf     { elem, name, value, reason -> name == '-custom-thing' }
keepCommentIf   { node -> true }

eachNode     { node -> /* ... */ }
eachDocument { doc -> /* ... */ }

// Return the URL to use; an empty string DROPS the attribute.
// Returning null means "no rewrite" rather than "drop".
rewriteUrls { elem, raw, resolved -> resolved.replace('example.com', 'cdn.example.net') }
```

Predicate results go through **Groovy truth**, so a closure that falls off the
end (returning null) means "do not keep" rather than throwing an unboxing
`NullPointerException`. The shorter arities also work — `keepTagIf { node -> }`,
`rewriteUrls { resolved -> }`.

## Extension methods

`META-INF/groovy/...ExtensionModule` registers operators on the Java binding's
own types, so they apply without wrapping them. Wrapping would be the wrong
move: `Node` and `Attribute` are **borrowed** views that die when `sanitize`
returns, and a wrapper is exactly the thing someone retains by accident.

```groovy
s.allowedTags() << 'my-widget'      // allow
s.allowedTags() << ['b', 'i']       // bulk
s.allowedTags() - 'script'          // deny
s.keepChildNodes = true             // property form

elem['onclick']?.value()            // attribute by name, or null
node.text                           // text/comment content
doc.walk()                          // depth-first List<Node>, inclusive

s.configure { allowTags 'late-addition' }   // reconfigure an existing sanitizer
```

`walk()` returns a `List`, not a lazy stream, on purpose: the DOM is freed when
`sanitize` returns, so a lazy walk escaping the callback would dereference freed
memory.

## Tests

```
aeb groovy/.tests.ae
```

or directly:

```
HS_JAVA_CLASSES=../target/.aeb/java-classes \
HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so \
  ./run-tests.sh
```

The suite is a plain main method, not Spock or JUnit — same reason as the Java
binding's: it must run with nothing but a JDK and the Groovy jar, so it works
offline and cannot fail resolving a test-framework artifact.

It mirrors the 12 checks in `docs/conformance.md` and adds the remaining
callback shapes, plus checks specific to this layer (that the block applies its
configuration, that it closes the handle when the block throws, that a null
predicate return means "do not keep", that `rewriteUrls` returning null does not
strip the URL).

> One of those extras earned its keep immediately. An early version of this
> layer evaluated predicate results with `DefaultGroovyMethods.asBoolean(Object)`,
> which answers "is this a non-null object?" and so returns **true for
> `Boolean.FALSE`**. Every "do not keep" answer was silently inverted:
> `keepTagIf { ... false }` *cancelled* the removal and kept the disallowed tag.
> Checks 10 and `on_removing_attribute` caught it. The fix is
> `DefaultTypeTransformation.castToBoolean`, which is the function that actually
> implements Groovy truth.

## Toolchain

`groovy/.tests.ae` **skips** rather than failing if no usable Groovy is present,
printing `groovy: skipped: ...`. "Usable" is a stronger condition than "on
PATH", for two independent reasons:

1. `groovyc` **loads** the classes it compiles against into its own JVM. The
   Java binding's classes are JDK 22+ bytecode (the FFM API does not exist
   before 22), so Groovy must be running on a JDK 22+ VM or it dies with
   `UnsupportedClassVersionError: class file version 68.0`. Debian's `groovy`
   package is 2.4 on JDK 17 and fails exactly that way.
2. `Object.withCloseable` arrived in **Groovy 4**. Groovy 3 compiles this
   binding perfectly well and then fails at *run* time with
   `MissingMethodException`, which looks like a binding bug but is not.

So `run-tests.sh` does not trust `command -v groovy`. It probes candidates
newest-first and verifies each by **compiling against the real Java classes and
then running a snippet that calls `withCloseable`** — checking only the compile
is how a Groovy 3 jar gets selected and the suite fails halfway through.

Candidates:

1. `$GROOVY_JAR`, if you point it at a core `groovy-<version>.jar`
2. `$GROOVY_HOME/lib`, or the lib directory of a `groovy` on `PATH`
3. a core groovy jar from `~/.m2` or a Gradle distribution

If none works, the script exits 77 and the aeb node reports a skip. It does not
report a pass.

## Engine resolution

Inherited from the Java binding:

1. an explicit path — `htmlSanitizer('/path/to/libhtmlsanitizer.so') { }`
2. `$HTMLSANITIZER_LIB`, then the `htmlsanitizer.lib` system property
3. `native/` beside the jar
4. the OS loader's own search path
