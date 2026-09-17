# The C ABI (`aether_hs_embed_*`)

The one seam every binding speaks to. Defined by
[`core/embed.ae`](../core/embed.ae) (the Aether side) and
[`core/_embed_support.c`](../core/_embed_support.c) (the string bridge and
callback trampolines). [`core_tests/abi_smoke.c`](../core_tests/abi_smoke.c)
is a complete, working consumer in ~300 lines of C — read it alongside this.

`rust/src/native.rs` is the canonical 1:1 symbol table in a real binding.

## Ground rules

1. **Every returned `char*` is caller-owned.** Copy it out, then free it with
   `aether_hs_embed_free_string`. Forgetting this is the single most common
   binding bug; it leaks on every call.
2. **The handle is opaque.** `aether_hs_embed_new()` returns a `void*`; every
   other call takes it. N sanitizers coexist independently in one process.
   A NULL handle is safe to pass everywhere (calls become no-ops returning
   empty/zero) — no binding needs a null check of its own.
3. **Signatures are scalar-only.** No structs by value, no tuples, no Aether
   types cross the boundary. Everything is `void*`, `int`, or `const char*`,
   so even a minimal FFI can describe the whole surface.
4. **The ABI is append-only.** Never renumber a constant or change a
   signature; add a symbol instead. `aether_hs_embed_abi_version()` reports
   the revision (currently `1`).

## Lifecycle

```c
void* h = aether_hs_embed_new();                       // create (secure defaults)
char* out = aether_hs_embed_sanitize(h, html, base);   // use, repeatedly
aether_hs_embed_free_string(out);                      // free every result
aether_hs_embed_free(h);                               // release the handle
```

| Symbol | Signature | Notes |
|---|---|---|
| `new` | `void* ()` | populates the secure default allow-lists |
| `free` | `void (void* h)` | releases the handle and its callback boxes |
| `free_string` | `void (char* s)` | frees any string this ABI returned |
| `sanitize` | `char* (void* h, const char* html, const char* base_url)` | `base_url` may be `""` |
| `sanitize_document` | `char* (void* h, const char* html, const char* base_url)` | |
| `normalize` | `char* (void* h, const char* html, const char* base_url)` | structural repair only — removes nothing |
| `abi_version` | `int ()` | currently `1` |

## Baselines

| Symbol | Signature | Returns |
|---|---|---|
| `use_baseline` | `int (void* h, int baseline)` | 1 on success, 0 for an unknown id |

| id | baseline |
|---|---|
| 0 | default web policy (a no-op — `new()` installs it) |
| 1 | email-safe |

A baseline names the OUTCOME rather than making a caller assemble it from
forty setters. **Email-safe** drops form controls (a form in an email is a
phishing primitive — it renders as a login box and posts wherever the author
says), SVG, interactive/obsolete elements, and document structure; it keeps
`a` and `img`, and adds `mailto:` to the scheme allow-list.

It **replaces** the allow-lists rather than intersecting, so apply it *before*
per-call configuration — anything added afterwards sticks, which is how a
caller narrows further:

```c
aether_hs_embed_use_baseline(h, 1);          /* email-safe */
aether_hs_embed_disallow(h, 0, "img");       /* ...and no images either */
```

A baseline only ever narrows the default policy; it never widens it.

## Normalize vs sanitize

Two separable jobs on one handle:

- **`normalize`** parses, repairs structure (closes unclosed elements, fixes
  nesting) and re-serializes canonically. It makes **no security judgement**:
  `<script>` and `onclick` survive, and the removal report stays empty. Use it
  when you want well-formed HTML and will apply your own policy.
- **`sanitize`** does that structural work *and* filters by policy, then
  records what it dropped.

## Removal report

What the last `sanitize` removed, and why. Read it after the call — the report
describes that call, not the handle's history.

| Symbol | Signature | Returns |
|---|---|---|
| `removal_count` | `int (void* h)` | number of entries |
| `removal_reason` | `int (void* h, int i)` | a `REASON_*` constant, `-1` out of range |
| `removal_name` | `char* (void* h, int i)` | `"script"`, `"onclick"`, `"#comment"` |
| `removal_detail` | `char* (void* h, int i)` | what it contained, truncated to 200 bytes |

```c
char* clean = aether_hs_embed_sanitize(h, html, "");
for (int i = 0; i < aether_hs_embed_removal_count(h); i++) {
    char* name = aether_hs_embed_removal_name(h, i);
    char* what = aether_hs_embed_removal_detail(h, i);
    /* e.g. name="script", what="alert(1)" */
    aether_hs_embed_free_string(name);
    aether_hs_embed_free_string(what);
}
```

This is a **pull** API rather than only the `on_removing_*` callbacks on
purpose: the WASM and BEAM bindings cannot hand the sanitizer core a function pointer
at all, and a caller who wants a summary rather than the ability to *cancel* a
removal should not have to install a hook to get one. The callbacks remain the
way to intervene; the report is the way to observe.

## Flags

| Symbol | Signature |
|---|---|
| `set_keep_child_nodes` / `get_keep_child_nodes` | `void (void* h, int on)` / `int (void* h)` |
| `set_allow_data_attributes` / `get_allow_data_attributes` | `void (void* h, int on)` / `int (void* h)` |

## Allow-lists

Six parallel policy sets, addressed by an `int` selector rather than six
duplicated symbol families:

| Selector | Set |
|---|---|
| 0 | allowed tags |
| 1 | allowed attributes |
| 2 | allowed CSS properties |
| 3 | allowed URL schemes |
| 4 | allowed CSS classes |
| 5 | URI attributes (which attributes hold URLs) |

| Symbol | Signature | Returns |
|---|---|---|
| `allow` | `int (void* h, int which, const char* item)` | 1 on success |
| `disallow` | `int (void* h, int which, const char* item)` | 1 on success |
| `is_allowed` | `int (void* h, int which, const char* item)` | 1 if present |
| `clear` | `int (void* h, int which)` | empties the set |
| `count` | `int (void* h, int which)` | size |
| `item_at` | `char* (void* h, int which, int index)` | owned string; `""` out of range |

`count` + `item_at` enumerate a set. Order is unspecified but stable between
mutations. `item_at` snapshots internally, so walking a set is O(n²) — fine
for policy lists read at configuration time, not for a hot loop.

## Callbacks

```c
aether_hs_embed_on_removing_tag(h, (void*)my_fn, my_user_data);
```

Pass a NULL `fn` to clear a hook. `user_data` is opaque and handed back as
the **first argument** on every invocation — bindings use it to find the
object or closure that owns the callback.

**Widths are C `int`, not `long`.** Aether's codegen emits the sanitizer core's
closure calls as `int(*)(...)`; a host declaring `long` gets a 4-vs-8-byte
mismatch on LP64, producing garbage `reason` values and corrupted stack
arguments.

| Hook | Host-side C signature |
|---|---|
| `on_removing_tag` | `int f(void* ud, void* node, int reason)` |
| `on_removing_attribute` | `int f(void* ud, void* elem, void* attr, int reason)` |
| `on_removing_style` | `int f(void* ud, void* elem, const char* name, const char* value, int reason)` |
| `on_removing_comment` | `int f(void* ud, void* node)` |
| `on_post_process_node` | `void f(void* ud, void* node)` |
| `on_post_process_dom` | `void f(void* ud, void* doc)` |
| `on_filter_url` | `char* f(void* ud, void* elem, const char* raw, const char* resolved)` |

- For the `removing_*` family (including `on_removing_comment`), a
  **non-zero return cancels the removal** — the node, attribute or property
  is kept.
- `on_filter_url` returns the URL to use. Return the `resolved` pointer
  unchanged for "no rewrite", `""` to drop the attribute, or a **malloc'd**
  string the sanitizer core takes ownership of. The sanitizer core exports `hs_raw_dup` (its
  own strdup) so a binding need not bind libc separately.
- **Keep your callback alive.** A garbage-collected trampoline that the
  sanitizer core later calls will crash the process. Every binding here pins them for
  the sanitizer's lifetime.

### Removal reasons

`0` not-allowed tag · `1` not-allowed attribute · `2` not-allowed style ·
`3` not-allowed URL value · `4` not-allowed value · `5` not-allowed CSS class ·
`6` class attribute empty · `7` style attribute empty

## DOM accessors

Valid **only inside a callback** — the pointers are borrowed and the DOM is
freed when `sanitize` returns. Do not retain them.

| Symbol | Signature |
|---|---|
| `node_kind` | `int (void* n)` — 1=Document, 2=Element, 3=Text, 4=Comment |
| `node_name` | `char* (void* n)` — tag name; `""` for non-elements |
| `node_value` | `char* (void* n)` — text/comment content |
| `node_parent` | `void* (void* n)` — NULL at the root |
| `node_child_count` / `node_child_at` | `int (void* n)` / `void* (void* n, int i)` |
| `node_attr_count` / `node_attr_at` | `int (void* n)` / `void* (void* n, int i)` |
| `attr_name` / `attr_value` | `char* (void* a)` |
| `attr_set_value` | `void (void* a, const char* v)` — **copies** `v`, so a transient host buffer is safe |

## What is deliberately not exposed

- `on_removing_css_class` — the sanitizer core declares the slot but never calls it
  (a gap in the original port). Exposing it would offer a hook that silently
  never fires.
- `sanitize_dom` — takes and returns an Aether DOM pointer, which has no
  meaning to a host that cannot construct one.
- `disallow_css_property_value_regex` — needs a compiled `std.regex` handle;
  it would require exposing regex lifetime management across the ABI.
