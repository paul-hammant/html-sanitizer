# htmlsanitizer — Clojure

Cleans HTML of constructs that can lead to XSS.

This layer is **idiomatic sugar only**. It carries no sanitizer logic *and no
FFI*: it calls the Java binding (`java/`, FFM / Panama) and reaches the
pure-Aether engine in `core/htmlsanitizer.ae` through it, by ordinary JVM
interop.

That is deliberate. There is exactly **one** FFI per runtime in this monorepo,
and on the JVM it is `java/src/main/java/org/htmlsanitizer`. A Clojure-specific
FFI would be a second copy of the ABI's marshalling and ownership rules to keep
in step with `core/embed.ae` — and the first thing to drift. Kotlin, Scala,
Clojure and Groovy are all thin layers over the same Java classes.

## Requirements

* **JDK 22 or newer** — the FFM API the Java binding uses is final in 22, so
  `--enable-preview` is *not* needed, but `--enable-native-access=ALL-UNNAMED`
  is.
* **Clojure 1.11 or newer.** No AOT step: the namespaces load from source.

## Use

`sanitizer` returns an `AutoCloseable`, so **`with-open` is the idiom** — which
is exactly why there is no bespoke macro here:

```clojure
(require '[org.htmlsanitizer.core :as hs])

(with-open [s (hs/sanitizer)]
  (hs/allow! s :tags "my-widget")
  (hs/keep-child-nodes! s true)

  (hs/sanitize s "<div onclick=\"alert(1)\">Hello</div>")
  ;; => "<div>Hello</div>"

  ;; Relative URLs resolve against a base.
  (hs/sanitize s "<img src=\"logo.png\">" "https://example.com"))
```

For the one-off case there is `sanitize-once`, which creates and closes for you:

```clojure
(hs/sanitize-once "<div onclick=\"alert(1)\">Hello</div>")
;; => "<div>Hello</div>"
```

The sanitizer is **not thread-safe** — the engine calls hooks re-entrantly
during `sanitize`.

## Allow-lists

Six live views, selected by keyword: `:tags`, `:attributes`, `:css-properties`,
`:schemes`, `:classes`, `:uri-attributes`. They are views on the engine, not
copies.

```clojure
(hs/allow! s :tags "my-widget" "my-other-widget")   ; allow (variadic)
(hs/disallow! s :tags "script")                     ; deny
(hs/allowed? s :schemes "http")                     ; query
(hs/allow-count s :schemes)                         ; live count
(hs/allowed s :schemes)                             ; snapshot as a set
(hs/clear! s :tags)                                 ; empty it
(hs/replace-allowed! s :tags "b" "i")               ; start from nothing
```

`allow!`, `disallow!`, `clear!` and `replace-allowed!` all return the sanitizer,
so they thread:

```clojure
(-> (hs/sanitizer)
    (hs/allow! :tags "my-widget")
    (hs/disallow! :attributes "style")
    (hs/keep-child-nodes! true))
```

An unknown selector throws `IllegalArgumentException` rather than silently
doing nothing.

## Callbacks

Ordinary Clojure fns; the SAM wrapping happens once, here. Each installer
returns the sanitizer, so they thread and stack in `doto`. Passing `nil` clears
a hook.

```clojure
;; Returning logical true from a keep-*-if! handler CANCELS the removal —
;; it KEEPS the thing.
(hs/keep-tag-if!       s (fn [node reason] (= "keep-me" (hs/node-name node))))
(hs/keep-attribute-if! s (fn [elem attr reason] false))
(hs/keep-style-if!     s (fn [elem nm v reason] (= "-custom-thing" nm)))
(hs/keep-comment-if!   s (constantly true))

(hs/each-node!     s (fn [node] ...))
(hs/each-document! s (fn [doc] ...))

;; Return the URL to use; an empty string DROPS the attribute.
;; Returning nil means "no rewrite" rather than "drop".
(hs/rewrite-urls! s (fn [elem raw resolved]
                      (clojure.string/replace resolved "example.com" "cdn.example.net")))
```

They are named `keep-*-if!` rather than `on-removing-*` because the ABI's rule
is "non-zero **cancels** the removal" — naming them after the event would read
as though returning true meant "remove it", the opposite of the truth.

Predicate results go through **Clojure truthiness**, so a fn returning `nil`
means "do not keep" rather than throwing on unboxing.

Removal reasons arrive as keywords — `:not-allowed-tag`,
`:not-allowed-attribute`, `:not-allowed-style`, `:not-allowed-url-value`,
`:not-allowed-value`, `:not-allowed-css-class`, `:class-attribute-empty`,
`:style-attribute-empty` — or `:unknown` for a code this build does not know.
The ABI's constants are append-only, so `:unknown` is a newer engine, not an
error.

## A policy as data

`configure!` applies a map, for when the policy is itself a value:

```clojure
(with-open [s (hs/configure! (hs/sanitizer)
                             {:keep-child-nodes true
                              :allow    {:tags ["my-widget"]}
                              :disallow {:attributes ["style"]}
                              :keep-tag-if (fn [n _] (= "keep-me" (hs/node-name n)))})]
  (hs/sanitize s "..."))
```

## The DOM

`Node` and `Attribute` handed to a callback are **borrowed** — the DOM is freed
when `sanitize` returns, so retaining one leaves a dangling pointer.

```clojure
(hs/node-kind node)        ; :document / :element / :text / :comment
(hs/node-name node)
(hs/node-value node)
(hs/children node)         ; vector of borrowed Nodes
(hs/attributes node)       ; vector of borrowed Attributes
(hs/attribute node "src")  ; one, by name, or nil
(hs/attr-name a) (hs/attr-value a)
(hs/set-attr-value! a "safe")
(hs/walk node)             ; depth-first vector, inclusive, fully realised
```

`walk` is realised eagerly rather than lazily on purpose: a lazy seq forced
after the callback returned would dereference freed memory.

When you want to keep something, snapshot it:

```clojure
(hs/each-document! s (fn [doc] (reset! captured (hs/node->map doc))))
;; @captured is plain immutable Clojure data — safe long after sanitize returned
```

`node->map` and `attr->map` exist precisely because "hold onto this node" is the
reflex a Clojure user will have, and the raw `Node` is the one thing they must
not hold.

## Tests

```
aeb clojure/.tests.ae
```

or directly:

```
HS_JAVA_CLASSES=../target/.aeb/java-classes \
HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so \
  ./run-tests.sh
```

or with the Clojure CLI:

```
HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so \
  clojure -M:local-java:test
```

The suite uses `clojure.test`, so the run needs nothing but the Clojure jar
itself — it works offline and cannot fail resolving a test-framework artifact.

It mirrors the 12 checks in `docs/conformance.md` and adds the remaining
callback shapes, plus checks specific to this layer (that `with-open` really
closes the handle when the body throws, that `node->map` survives the callback,
that a `nil` predicate return means "do not keep", that an unknown selector
throws).

## Toolchain

`clojure/.tests.ae` **skips** rather than failing if no Clojure runtime is
present, printing `clojure: skipped: clojure not installed`. Candidates:

1. `$CLOJURE_JARS` — a directory holding `clojure-<ver>.jar`,
   `spec.alpha-<ver>.jar` and `core.specs.alpha-<ver>.jar`. The no-install
   escape hatch, checked first. (All three are needed; without `spec.alpha` the
   runtime does not boot.)
2. clojure jars already in `~/.m2` or the Gradle caches
3. the `clojure` / `clj` CLI, which brings its own runtime

If none is found the script exits 77 and the aeb node reports a skip. It does
not report a pass.

```
CLOJURE_JARS=/path/to/clojure-jars aeb clojure/.tests.ae
```

## Engine resolution

Inherited from the Java binding:

1. an explicit path — `(hs/sanitizer "/path/to/libhtmlsanitizer.so")`
2. `$HTMLSANITIZER_LIB`, then the `htmlsanitizer.lib` system property
3. `native/` beside the jar
4. the OS loader's own search path
