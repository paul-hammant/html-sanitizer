# htmlsanitizer (Gleam)

Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).

This is a **thin Gleam surface** over the monorepo's one shared native engine —
`core/native/libhtmlsanitizer.so`, compiled from pure Aether. It contains **no
sanitizer logic**: every function marshals to an `aether_hs_embed_*` call
across the C ABI described in `core/embed.ae`.

## There is no C in this directory

The NIF is the **canonical BEAM binding** and lives in `erlang/`. It is
compiled exactly once, by `erlang/.build.ae`, and this project loads that
already-compiled artifact. Every function here is an
`@external(erlang, "htmlsanitizer_nif", ...)` binding onto the very same module
the Erlang and Elixir bindings load.

One engine, one NIF, three languages.

## Erlang target only

This package sets `target = "erlang"` in `gleam.toml`. The whole binding is a
NIF, so it cannot compile to JavaScript. Stating the target makes that a clear
manifest error rather than a confusing missing-module error at runtime. (The
monorepo already has a JavaScript binding that talks to the same engine over
koffi, if that is what you need.)

## Building and testing

```sh
aeb erlang/.build.ae     # builds the shared NIF
aeb gleam/.tests.ae      # runs this suite against it
```

Gleam honours `$ERL_LIBS`, so nothing clever is required — point it at the
**parent** of the built app directory (OTP looks for
`<lib_dir>/<app_name>/ebin`, so it must be `erlang/_build`, not
`erlang/_build/htmlsanitizer_nif`):

```sh
cd gleam
ERL_LIBS=../erlang/_build gleam test
```

`htmlsanitizer_nif` is deliberately **not** a `[dependencies]` entry — it is an
OTP app built outside Gleam and supplied on the code path. Listing it would
send Gleam looking on hex.pm for a package that does not exist there.

### Finding the engine

The NIF `dlopen`s the engine. Resolution order: `$HTMLSANITIZER_LIB`, then
`priv/` beside the NIF, then the OS loader's search path.

## Usage

```gleam
import htmlsanitizer.{Schemes, Tags}

pub fn main() {
  let assert Ok(s) = htmlsanitizer.new()

  htmlsanitizer.sanitize(s, "<div onclick=\"alert(1)\">Hello</div>")
  // -> "<div>Hello</div>"

  htmlsanitizer.close(s)
}
```

`sanitize` takes no base URL; `sanitize_with_base` resolves relative URLs:

```gleam
htmlsanitizer.sanitize_with_base(s, "<img src=\"logo.png\">", "https://example.com")
// -> "<img src=\"https://example.com/logo.png\">"
```

The lenient functions return `""` on a closed sanitizer. `try_sanitize` and
`try_sanitize_document` return `Result(String, Error)` when you need that
distinguished from a legitimately empty result.

### Policy lists

Six lists, named by a `PolicyList` value rather than the ABI's integer
selector: `Tags`, `Attributes`, `CssProperties`, `Schemes`, `Classes`,
`UriAttributes`. The integer never reaches a Gleam caller, so an out-of-range
selector is unrepresentable.

```gleam
htmlsanitizer.allow(s, Tags, "my-widget")
htmlsanitizer.allow_all(s, Tags, ["one", "two"])
htmlsanitizer.disallow(s, Tags, "div")
htmlsanitizer.is_allowed(s, Schemes, "http")     // True
htmlsanitizer.count(s, Schemes)                  // 2
htmlsanitizer.sorted_items(s, Schemes)           // ["http", "https"]
htmlsanitizer.clear(s, Schemes)                  // start from nothing
```

`items` returns the engine's own order (unspecified but stable between
mutations); `sorted_items` when you want determinism.

### Flags

```gleam
htmlsanitizer.set_keep_child_nodes(s, True)       // keep children of a removed tag
htmlsanitizer.set_allow_data_attributes(s, True)  // let data-* through
```

### Lifetime

A sanitizer is an `enif_resource`. The BEAM's GC releases the native handle
when the last reference goes, so a dropped sanitizer leaks nothing. `close`
makes that deterministic and is idempotent; after it, `is_closed` is `True` and
`try_sanitize` returns `Error(Closed)` rather than touching a freed pointer.

A sanitizer is **not** safe for concurrent use — the native handle carries
mutable policy state. Use one per process, or serialise access behind one.

## Conformance

`aeb gleam/.tests.ae` runs `test/htmlsanitizer_test.gleam`, which mirrors
`docs/conformance.md`.

> **Checks 10 and 11 are not implemented, by design.**
>
> Check 10 (`on_removing_tag` cancels a removal) and check 11
> (`on_filter_url` rewrites a URL) require the engine to call a *host* function
> synchronously from inside `sanitize`. On the BEAM that would mean calling
> back into the VM from a NIF and blocking the scheduler thread until a process
> replied — `enif_send` is one-way, and there is no safe synchronous
> "call a process and wait" primitive. It deadlocks outright when the calling
> process is the one being asked, and stalls a scheduler regardless.
>
> So the shared NIF registers **no** hooks and this module exposes none. The
> surface is *absent*, not faked. `docs/conformance.md` explicitly permits this
> for a binding whose language cannot express native callbacks.
>
> The remaining **ten** checks are covered in full, plus extras: every policy
> list is proved addressable (which catches a mistyped selector),
> `sanitize_document`, base-URL resolution, and closed-handle rejection.

This applies to all three BEAM bindings (Erlang, Elixir, Gleam) because all
three share the one NIF. If you need the hooks, use a binding whose language
can hold a C function pointer — Rust, Go, Python, Ruby, and the rest all
implement 10 and 11.
