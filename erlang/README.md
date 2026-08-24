# htmlsanitizer (Erlang)

Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).

This is a **thin NIF binding** over the monorepo's one shared native engine —
`core/native/libhtmlsanitizer.so`, compiled from pure Aether. It contains **no
sanitizer logic**: every function marshals to an `aether_hs_embed_*` call
across the C ABI described in `core/embed.ae`.

It is also the **canonical BEAM binding**. `elixir/` and `gleam/` do not ship
their own C — they build-depend on this node and load *this* compiled NIF over
the BEAM. One `.so`, three languages.

## Building

```sh
aeb erlang/.build.ae
```

That produces an ordinary OTP application:

```
erlang/_build/htmlsanitizer_nif/
    ebin/htmlsanitizer.beam
    ebin/htmlsanitizer_nif.beam
    ebin/htmlsanitizer_nif.app
    priv/htmlsanitizer_nif.so       the NIF
    priv/libhtmlsanitizer.so        the engine, staged
```

Put its **parent** on `ERL_LIBS` and OTP finds the app:

```sh
ERL_LIBS=erlang/_build erl
```

### Two ways to build it

**In your own Erlang toolchain** — `rebar.config` is here for exactly that:

```sh
rebar3 compile     # the NIF + the .beam files
rebar3 ct          # the conformance suite
```

The engine itself is not a rebar dependency; build it once first (see
"Finding the engine" below, and ../core).

**In this monorepo** — `aeb erlang/.build.ae`, which drives aeb's
`erlang.nif` builder. That is what our CI runs, because this repo builds
20+ language bindings from one dependency graph. It locates `erl_nif.h` by
asking the runtime for `code:root_dir()` rather than guessing
`/usr/lib/erlang`, so kerl, asdf, Homebrew and relocated installs all work.

Neither path wraps the other; both produce the same OTP application.

### Finding the engine

The NIF `dlopen`s the engine rather than linking it, so the BEAM can load this
module even when the engine is missing and report a clean error instead of
dying inside the dynamic linker. Resolution order:

1. `$HTMLSANITIZER_LIB`
2. `priv/` next to the NIF (the copy `.build.ae` stages)
3. the OS loader's own search path

## Usage

```erlang
{ok, S} = htmlsanitizer:new(),
<<"<div>Hello </div>">> =
    htmlsanitizer:sanitize(S, <<"<div>Hello <script>evil()</script></div>">>),
ok = htmlsanitizer:close(S).
```

`sanitize/3` takes a base URL for resolving relative URLs; `sanitize/2` passes
`<<>>` for "do not resolve". Input is `iodata()`, so an unflattened iolist is
fine. Output is always a binary.

```erlang
htmlsanitizer:sanitize(S, <<"<img src=\"logo.png\">">>, <<"https://example.com">>).
%% => <<"<img src=\"https://example.com/logo.png\">">>
```

`sanitize/2,3` return `<<>>` on a closed sanitizer. Use `sanitize_r/3` when you
need that distinguished from a legitimately empty result — it returns
`{ok, Binary} | {error, closed}`.

### Policy lists

Six lists, named by atom rather than by the ABI's integer selector:

`tags`, `attributes`, `css_properties`, `schemes`, `classes`, `uri_attributes`.

```erlang
htmlsanitizer:allow(S, tags, <<"my-widget">>),
htmlsanitizer:allow(S, tags, [<<"one">>, <<"two">>]),   %% bulk
htmlsanitizer:disallow(S, tags, <<"div">>),
true = htmlsanitizer:is_allowed(S, schemes, <<"http">>),
2 = htmlsanitizer:count(S, schemes),
[<<"http">>, <<"https">>] = htmlsanitizer:sorted_items(S, schemes),
htmlsanitizer:clear(S, schemes).                        %% start from nothing
```

`items/2` returns the engine's own order (unspecified but stable between
mutations); `sorted_items/2` when you want determinism.

### Flags

```erlang
htmlsanitizer:set_keep_child_nodes(S, true),      %% keep children of a removed tag
htmlsanitizer:set_allow_data_attributes(S, true). %% let data-* through
```

### Lifetime

A sanitizer is an `enif_resource`. The GC releases the native handle when the
last reference goes, so a dropped sanitizer leaks nothing. `close/1` makes that
deterministic and is idempotent; after it, `is_closed/1` is `true` and
`sanitize_r/3` returns `{error, closed}` rather than touching a freed pointer.

A sanitizer is **not** safe for concurrent use — the native handle carries
mutable policy state. Use one per process, or serialise access behind one.

### Scheduling

`sanitize/3` and `sanitize_document/3` parse arbitrary HTML, which can exceed
the ~1 ms a normal NIF may occupy a scheduler for. Both are flagged
`ERL_NIF_DIRTY_JOB_CPU_BOUND` so a large document degrades throughput rather
than BEAM scheduler fairness.

## Conformance

`aeb erlang/.tests.ae` runs the suite in `test/`, which mirrors
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
> So this binding registers **no** hooks. The hook surface is *absent*, not
> faked: `htmlsanitizer` exports no `on_removing_tag/2` or `on_filter_url/2`,
> and the test suite asserts that absence so the gap cannot rot into a silent
> hole. `docs/conformance.md` explicitly permits this for a binding whose
> language cannot express native callbacks.
>
> The remaining **ten** checks are covered in full, plus BEAM-specific extras:
> `iodata` input, resource GC of an unclosed sanitizer, closed-handle
> rejection, and `sanitize_document`.

This applies to all three BEAM bindings (Erlang, Elixir, Gleam) because all
three share this one NIF.
