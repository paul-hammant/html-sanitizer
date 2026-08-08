# htmlsanitizer — Rust binding

Cleans HTML of constructs that can lead to XSS.

This crate is **marshalling only**. The sanitizer itself — HTML5 tokenizer,
DOM, CSS parser, URL resolver, allow-lists — is the pure-Aether engine in
`core/htmlsanitizer.ae`, shared by every language binding in this monorepo and
reached through the `aether_hs_embed_*` C ABI (`core/embed.ae`).

`src/native.rs` is the **canonical 1:1 symbol table** for that ABI: every
exported symbol, in the order `core/embed.ae` declares it, with the exact C
signature. Other bindings are expected to be diffable against it.

## Install

```toml
[dependencies]
htmlsanitizer = "1"
```

The engine is loaded at runtime with [libloading](https://docs.rs/libloading).
Resolution order:

1. an explicit path — `HtmlSanitizer::with_library(Some(path))`
2. `$HTMLSANITIZER_LIB`
3. `native/` next to the crate
4. the OS loader's own search path

## Use

```rust
use htmlsanitizer::HtmlSanitizer;

let mut s = HtmlSanitizer::new()?;

assert_eq!(s.sanitize(r#"<div onclick="alert(1)">Hello</div>"#), "<div>Hello</div>");

s.allowed_tags().add("my-widget");
s.set_keep_child_nodes(true);

// Relative URLs resolve against a base.
let out = s.sanitize_with_base(r#"<img src="logo.png">"#, "https://example.com");
# Ok::<(), htmlsanitizer::Error>(())
```

The native handle is released on `Drop` — there is nothing to close by hand.

## Allow-lists

Six set-like views — `allowed_tags()`, `allowed_attributes()`,
`allowed_css_properties()`, `allowed_schemes()`, `allowed_classes()`,
`uri_attributes()`:

```rust
# use htmlsanitizer::HtmlSanitizer;
# let s = HtmlSanitizer::new().unwrap();
s.allowed_tags().add("my-widget");       // allow
s.allowed_tags().remove("script");       // deny
s.allowed_tags().contains("div");        // query
s.allowed_tags().len();                  // count
s.allowed_tags().to_vec();               // enumerate
s.allowed_tags().clear().extend(["b", "i"]);   // start from nothing
```

## Callbacks

All seven engine hooks are wired. Each `on_*` takes a `'static` closure and
returns `&mut Self`, so they chain.

```rust
# use htmlsanitizer::HtmlSanitizer;
# let mut s = HtmlSanitizer::new().unwrap();
// Returning true from a removing_* handler CANCELS the removal.
s.on_removing_tag(|node, _reason| node.name() == "keep-me");
s.on_removing_attribute(|_elem, _attr, _reason| false);
s.on_removing_style(|_elem, name, _value, _reason| name == "-custom-thing");
s.on_removing_comment(|_node| true);

s.on_post_process_node(|_node| { /* ... */ });
s.on_post_process_dom(|_doc| { /* ... */ });

// Rewrite a URL; an empty string drops the attribute.
s.on_filter_url(|_node, _raw, resolved| resolved.to_string());
```

`Node` and `Attribute` are **borrowed** views whose lifetime is tied to the
callback: the DOM is freed when `sanitize` returns, so the borrow checker
stops you retaining one.

`Node` exposes `kind()` (1=Document, 2=Element, 3=Text, 4=Comment), `name()`,
`value()`, `parent()`, `children()`, `attributes()`. `Attribute` exposes
`name()`, `value()` and `set_value()`.

## Tests

```
HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so cargo test
```

or, with the engine built for you:

```
aeb rust/.tests.ae
```

The suite is the 12-check conformance contract in `docs/conformance.md`, plus
extras covering the remaining callback shapes.

## Notes for maintainers

* **Every `*mut c_char` the ABI returns is caller-owned.** `Api::take_string`
  copies and frees it through `aether_hs_embed_free_string`; anything else
  leaks.
* Node/attribute pointers in a callback are **borrowed** for that call only.
  The `'a` lifetime on `Node`/`Attribute` encodes exactly that.
* Callback integer arguments are C `int`, not `long` — the doc comment in
  `core/embed.ae` says `long`, but the trampolines in `_embed_support.c` use
  `int`, and those are what actually run. See "ABI note" below.
* Hook closures live in a `Box<Hooks>` owned by the sanitizer; the `user_data`
  we register is a stable pointer to a boxed `CallbackCtx`. `Drop` frees the
  engine handle first, so no trampoline can fire after the closures go away.
* `on_filter_url` must hand the engine a **libc-malloc'd** string it then
  owns. `native::malloc_cstring` uses `malloc` directly, because a
  Rust-allocated buffer would be freed by the wrong allocator.

### ABI note

`core/embed.ae`'s callback documentation block writes the hook signatures with
`long` parameters (`long f(void* ud, void* node, long reason)`). The actual
trampolines in `core/_embed_support.c` declare them as `int`. On LP64 those
differ (4 vs 8 bytes), so the comment is the thing that is wrong; this binding
follows the C, as do the Python and C smoke-test bindings.
