# htmlsanitizer (Elixir)

Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).

This is a **thin Elixir surface** over the monorepo's one shared native engine
— `core/native/libhtmlsanitizer.so`, compiled from pure Aether. It contains
**no sanitizer logic**: every function marshals to an `aether_hs_embed_*` call
across the C ABI described in `core/embed.ae`.

## There is no C in this directory

The NIF is the **canonical BEAM binding** and lives in `erlang/`. It is
compiled exactly once, by `erlang/.build.ae`, and this project loads that
already-compiled artifact. Every function here `defdelegate`s to
`:htmlsanitizer_nif` — the very same module the Erlang and Gleam bindings load.

One engine, one NIF, three languages. Shipping a second copy of the C here
(the usual `elixir_make` + `c_src/` arrangement) would mean a second `.so` to
keep in step, which is exactly what this monorepo's one-engine rule forbids.

## Building and testing

```sh
aeb erlang/.build.ae     # builds the shared NIF
aeb elixir/.tests.ae     # runs this suite against it
```

### The Mix wrinkle

`erl`, `escript` and `gleam` all honour `$ERL_LIBS`, so the Erlang and Gleam
bindings find the NIF app for free. **Mix does not.** It builds its code path
from `deps/` and `_build/`, and an OTP application that Mix did not build is
invisible to it.

So `elixir/.tests.ae` passes the app directory in `$HTMLSANITIZER_BEAM_APP`,
and `test/test_helper.exs` calls `Code.append_path/1` on its `ebin/`. To run
`mix test` by hand:

```sh
aeb erlang/.build.ae
cd elixir
HTMLSANITIZER_BEAM_APP=../erlang/_build/htmlsanitizer_nif mix test
```

`test_helper.exs` also falls back to that in-tree path when the variable is
unset, so a plain `mix test` works after the Erlang node has been built.

### Finding the engine

The NIF `dlopen`s the engine. Resolution order: `$HTMLSANITIZER_LIB`, then
`priv/` beside the NIF, then the OS loader's search path.

## Usage

```elixir
{:ok, s} = HtmlSanitizer.new()
HtmlSanitizer.sanitize(s, ~s(<div onclick="alert(1)">Hello</div>))
# => "<div>Hello</div>"
HtmlSanitizer.close(s)
```

Prefer the bracket, which closes even if the body raises:

```elixir
HtmlSanitizer.with_sanitizer(fn s ->
  HtmlSanitizer.sanitize(s, html)
end)
```

`sanitize/3` takes a base URL for resolving relative URLs; it defaults to `""`
(no resolution). Input is `iodata`, so an unflattened iolist is fine.

```elixir
HtmlSanitizer.sanitize(s, ~s(<img src="logo.png">), "https://example.com")
# => ~s(<img src="https://example.com/logo.png">)
```

`sanitize/3` returns `""` on a closed sanitizer. Use `sanitize_r/3` when you
need that distinguished from a legitimately empty result — it returns
`{:ok, binary} | {:error, :closed}`.

### Policy lists

Six lists, named by atom rather than by the ABI's integer selector:
`:tags`, `:attributes`, `:css_properties`, `:schemes`, `:classes`,
`:uri_attributes`.

```elixir
HtmlSanitizer.allow(s, :tags, "my-widget")
HtmlSanitizer.allow(s, :tags, ["one", "two"])     # bulk
HtmlSanitizer.disallow(s, :tags, "div")
HtmlSanitizer.allowed?(s, :schemes, "http")       # true
HtmlSanitizer.count(s, :schemes)                  # 2
HtmlSanitizer.sorted_items(s, :schemes)           # ["http", "https"]
HtmlSanitizer.clear(s, :schemes)                  # start from nothing
```

`items/2` returns the engine's own order (unspecified but stable between
mutations); `sorted_items/2` when you want determinism.

### Flags

```elixir
HtmlSanitizer.set_keep_child_nodes(s, true)       # keep children of a removed tag
HtmlSanitizer.set_allow_data_attributes(s, true)  # let data-* through
```

### Lifetime

A sanitizer is an `enif_resource`. The BEAM's GC releases the native handle
when the last reference goes, so a dropped sanitizer leaks nothing. `close/1`
makes that deterministic and is idempotent; after it, `closed?/1` is `true` and
`sanitize_r/3` returns `{:error, :closed}` rather than touching a freed
pointer.

A sanitizer is **not** safe for concurrent use — the native handle carries
mutable policy state. Use one per process, or serialise access behind one.

### Scheduling

`sanitize` and `sanitize_document` are flagged `ERL_NIF_DIRTY_JOB_CPU_BOUND` in
the NIF, because parsing arbitrary HTML can exceed the ~1 ms a normal NIF may
occupy a scheduler for. A large document therefore costs throughput, not BEAM
scheduler fairness.

## Conformance

`aeb elixir/.tests.ae` runs `test/html_sanitizer_test.exs`, which mirrors
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
> surface is *absent*, not faked, and the test suite asserts that absence so
> the gap cannot rot into a silent hole. `docs/conformance.md` explicitly
> permits this for a binding whose language cannot express native callbacks.
>
> The remaining **ten** checks are covered in full, plus BEAM-specific extras:
> `iodata` input, resource GC of an unclosed sanitizer, closed-handle
> rejection, `with_sanitizer` unwinding on a raise, and `sanitize_document`.

This applies to all three BEAM bindings (Erlang, Elixir, Gleam) because all
three share the one NIF. If you need the hooks, use a binding whose language
can hold a C function pointer — Rust, Go, Python, Ruby, and the rest all
implement 10 and 11.
