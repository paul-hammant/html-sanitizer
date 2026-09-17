# The binding conformance suite

Every binding implements the **same** small set of checks. They are the
contract: if a binding passes these, it is wired correctly; if it fails one,
the bug is in that binding's marshalling, never in the sanitizer core (the sanitizer core is
proven separately by `core_tests/.tests.ae` and `core_tests/.abi.ae`).

Keep this list short on purpose. It is not a sanitizer test suite — the C#
behavioural cases live in `core_tests/probe.ae` and run once, against the
sanitizer core. A binding only has to prove that **each kind of value crosses the FFI
correctly**, which is what these twelve checks sample.

| # | Check | What it would catch |
|---|---|---|
| 1 | `sanitize("<div>Hello <script>alert(1)</script> world!</div>")` → `<div>Hello  world!</div>` | the basic string round-trip; a broken `char*` decode |
| 2 | `sanitize("<div onclick=\"alert(1)\">Hello</div>")` → `<div>Hello</div>` | attribute filtering reached at all |
| 3 | `sanitize("")` → `""` | empty-string marshalling (a classic NULL-vs-"" bug) |
| 4 | non-ASCII: `sanitize("<div>café ☕</div>")` → unchanged | UTF-8 across the boundary, not Latin-1 |
| 5 | `allowed_tags.add("my-widget")` then sanitize keeps `<my-widget>` | allow-list mutation (int selector + string) |
| 6 | `allowed_tags` removal drops a previously-allowed tag | the `disallow` direction |
| 7 | `"http" in allowed_schemes` is true; count is 2 | the query + count path |
| 8 | enumerating `allowed_schemes` yields `http` and `https` | the `item_at` / MapKeys read path |
| 9 | `keep_child_nodes = True` keeps children of a removed tag | boolean flags marshalled as int |
| 10 | `on_removing_tag` returning true keeps a disallowed tag | the callback trampoline + cancel semantics |
| 11 | `on_filter_url` rewrites a resolved URL | the string-returning callback (hardest shape) |
| 12 | two sanitizers are independent | the handle really is per-instance |

**`sanitize` vs `sanitize_document`.** They are not aliases. `sanitize` emits
a **fragment**, unwrapping any document structure the input carried;
`sanitize_document` emits a **whole document**, adding
`<html><head></head><body>…</body></html>` when the input lacks it. Every
binding's suite pins this, because aliasing them (as this repo did until the
normalize/sanitize split) silently satisfies neither direction.

Checks 10 and 11 are the ones worth being careful about — they are where a
binding is most likely to be subtly wrong (a garbage-collected callback, a
string returned with the wrong ownership). A binding whose language cannot
express native callbacks at all may skip 10–11 and must say so in its README.

## Running one binding

```
aeb <lang>/.tests.ae
```

Each `.tests.ae` deps `core/.build.ae`, so the sanitizer core builds first and the
binding gets its path via `HTMLSANITIZER_LIB`.

## Running everything

```
aeb .presubmit.ae
```
