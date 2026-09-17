# htmlsanitizer — Python binding

Clean HTML of XSS vectors. A thin `ctypes` binding over the shared native
sanitizer core (`libhtmlsanitizer.so`) that every language binding in this monorepo
uses, so behaviour is identical across languages by construction.

```python
from htmlsanitizer import HtmlSanitizer

s = HtmlSanitizer()
s.sanitize('<div onclick="steal()">hi <script>alert(1)</script></div>')
# '<div>hi </div>'
```

## Install

The wheel bundles the sanitizer core `.so`, so a plain install is enough:

```sh
pip install htmlsanitizer
```

## Finding the sanitizer core

Resolution order:

1. an explicit path — `HtmlSanitizer(native_lib="/path/to/libhtmlsanitizer.so")`
2. `$HTMLSANITIZER_LIB`
3. `native/` bundled inside the installed package (what the wheel ships)
4. the OS loader's search path

## Configuring

Six policy sets, each a mutable set-like view:

```python
s.allowed_tags.add("my-widget")
s.allowed_tags.discard("marquee")
s.allowed_attributes.update(["role", "aria-label"])
s.allowed_schemes.clear()          # start from nothing
s.allowed_schemes.add("https")     # https only

"http" in s.allowed_schemes        # membership
sorted(s.allowed_tags)             # enumerate
len(s.allowed_css_properties)
```

Also `s.allowed_css_properties`, `s.allowed_classes`, `s.uri_attributes`.

Two flags:

```python
s.keep_child_nodes = True          # keep children of a removed element
s.allow_data_attributes = True     # let data-* through
```

## Callbacks

For the `removing_*` family, **returning true cancels the removal** — the
node, attribute or property is kept.

```python
s.on_removing_tag(lambda node, reason: node.name == "keep-me")
s.on_removing_attribute(lambda elem, attr, reason: attr.name == "data-keep")
s.on_removing_style(lambda elem, name, value, reason: name.startswith("--"))
s.on_removing_comment(lambda node: True)          # keep all comments
s.on_post_process_node(lambda node: ...)
s.on_post_process_dom(lambda doc: ...)

# Rewrite URLs as they are resolved. Return "" to drop the attribute.
s.on_filter_url(lambda elem, raw, resolved:
                resolved.replace("http://", "https://"))
```

`node` and `attr` are borrowed views (`Node`, `Attribute`) valid only for the
duration of the callback — the DOM is freed when `sanitize` returns. Read
`node.name` / `.value` / `.kind` / `.children` / `.attributes` / `.parent`, and
`attr.name` / `.value` (settable). Do not retain them.

## Lifecycle

The native handle is released by `close()`, by `__del__`, or by using the
sanitizer as a context manager:

```python
with HtmlSanitizer() as s:
    clean = s.sanitize(html)
```

## Tests

```sh
aeb python/.tests.ae          # from the repo root
```

Mirrors `docs/conformance.md` — the twelve checks every binding implements —
plus the remaining callback shapes. See the root README for the known
per-`sanitize()` memory-growth caveat, which is core-side and affects all
bindings equally.
