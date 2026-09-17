# htmlsanitizer — Java binding (FFM / Panama)

Cleans HTML of constructs that can lead to XSS.

This package is **marshalling only**. The sanitizer itself — HTML5 tokenizer,
DOM, CSS parser, URL resolver, allow-lists — is the pure-Aether sanitizer core in
`core/htmlsanitizer.ae`, shared by every language binding in this monorepo and
reached through the `aether_hs_embed_*` C ABI (`core/embed.ae`).

## Requirements

* **JDK 22 or newer.** The binding uses the Foreign Function & Memory API
  (JEP 454), which is *final* in 22 — so `--enable-preview` is **not** needed.
  Developed and tested against JDK 24.
* `--enable-native-access=ALL-UNNAMED` on the command line. Without it the JVM
  warns today and will refuse in a future release.

```
java --enable-native-access=ALL-UNNAMED -cp out com.example.Main
```

The sanitizer core is loaded at runtime. Resolution order:

1. an explicit path — `new HtmlSanitizer("/path/to/libhtmlsanitizer.so")`
2. `$HTMLSANITIZER_LIB`, then the `htmlsanitizer.lib` system property
3. `native/` beside the jar
4. the OS loader's own search path

## Use

```java
import org.htmlsanitizer.HtmlSanitizer;

try (HtmlSanitizer s = new HtmlSanitizer()) {
    System.out.println(s.sanitize("<div onclick=\"alert(1)\">Hello</div>"));
    // -> <div>Hello</div>

    s.allowedTags().add("my-widget");
    s.keepChildNodes(true);

    // Relative URLs resolve against a base.
    s.sanitize("<img src=\"logo.png\">", "https://example.com");
}
```

`HtmlSanitizer` is `AutoCloseable`; `close()` releases the native handle and
the upcall stubs. It is **not thread-safe** — the sanitizer core calls hooks
re-entrantly during `sanitize`.

## Allow-lists

Six set-like views — `allowedTags()`, `allowedAttributes()`,
`allowedCssProperties()`, `allowedSchemes()`, `allowedClasses()`,
`uriAttributes()`:

```java
s.allowedTags().add("my-widget");        // allow
s.allowedTags().remove("script");        // deny
s.allowedTags().contains("div");         // query
s.allowedTags().size();                  // count
s.allowedTags().toList();                // enumerate (also Iterable)
s.allowedTags().clear().addAll("b", "i");    // start from nothing
```

## Callbacks

All seven sanitizer core hooks are wired. Each `on*` returns `this`, so they chain;
passing `null` clears a hook.

```java
// Returning true from a removing* handler CANCELS the removal.
s.onRemovingTag((node, reason) -> node.name().equals("keep-me"));
s.onRemovingAttribute((elem, attr, reason) -> false);
s.onRemovingStyle((elem, name, value, reason) -> name.equals("-custom-thing"));
s.onRemovingComment(node -> true);

s.onPostProcessNode(node -> { /* ... */ });
s.onPostProcessDom(doc -> { /* ... */ });

// Rewrite a URL; an empty string drops the attribute.
s.onFilterUrl((node, raw, resolved) -> resolved.replace("example.com", "cdn.example.net"));
```

`Node` and `Attribute` are **borrowed** views — the DOM is freed when
`sanitize` returns, so do not retain them past the callback.

`Node` exposes `kind()` (1=Document, 2=Element, 3=Text, 4=Comment), `name()`,
`value()`, `parent()`, `children()`, `attributes()`. `Attribute` exposes
`name()`, `value()` and `setValue()`.

## Tests

The conformance suite is a **plain main method**, not JUnit:

```
javac -d out $(find src -name '*.java')
HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so \
  java --enable-native-access=ALL-UNNAMED -cp out org.htmlsanitizer.ConformanceTest
```

or, with the sanitizer core built for you:

```
aeb java/.tests.ae
```

### Why not JUnit

The suite must run with nothing but a JDK, so `java/.tests.ae` works offline
and cannot fail on Maven artifact resolution — a test framework would be the
only part of the whole binding that needed a network fetch. The assertions are
a dozen lines of `assertEquals`/`assertTrue`.

`pom.xml` is still provided for downstream consumers, and declares JUnit 5 in
test scope for anyone who wants to run the checks under `mvn test`; the checks
are plain methods, so wrapping them in `@Test` is mechanical.

## Notes for maintainers

* **Every `char*` the ABI returns is caller-owned.** `Native.takeString`
  copies and frees it through `aether_hs_embed_free_string`; anything else
  leaks. A returned `MemorySegment` has `byteSize == 0`, so it must be
  `reinterpret`ed before the string can be read.
* Upcall targets **must not declare checked exceptions** — `Linker.upcallStub`
  rejects the handle outright. Wrap anything thrown.
* Upcall stubs live in a shared `Arena` closed only by `close()`, and `close()`
  frees the sanitizer core handle *first*, so no stub can fire after it disappears.
* `on_filter_url` must hand the sanitizer core a **libc-malloc'd** string it then
  owns. `Native.mallocString` does that; an `Arena` allocation would be freed
  by the wrong allocator.
* `Attribute.setValue` has the same constraint for a different reason: the ABI
  stores the pointer directly into the DOM (`at.value = value`) rather than
  copying it, so a confined-`Arena` buffer would be released while the DOM
  still pointed at it.

### ABI note

`core/embed.ae`'s callback documentation block writes the hook signatures with
`long` parameters (`long f(void* ud, void* node, long reason)`). The actual
trampolines in `core/_embed_support.c` declare them as `int`. On LP64 those
differ (4 vs 8 bytes), so the comment is the thing that is wrong; this binding
follows the C, as do the Python, Rust and C smoke-test bindings.
