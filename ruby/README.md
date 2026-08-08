# htmlsanitizer (Ruby)

Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).

This gem is a **thin Fiddle binding** over the monorepo's one shared native
engine — `core/native/libhtmlsanitizer.so`, compiled from pure Aether. It
contains **no sanitizer logic**: every method marshals to an
`aether_hs_embed_*` call. That is deliberate. One engine, one set of
behaviours, N language surfaces.

## Install

The gem needs the engine `.so` at runtime. In-tree:

```sh
cd core && ae build --emit=lib embed.ae --extra _embed_support.c \
    -o native/libhtmlsanitizer.so
export HTMLSANITIZER_LIB=$PWD/native/libhtmlsanitizer.so
```

The loader looks in this order:

1. an explicit path — `HtmlSanitizer::Sanitizer.new(native_lib: "/path/to/lib.so")`
2. `$HTMLSANITIZER_LIB`
3. `native/` bundled next to the gem (`rake stage_native` puts it there)
4. the OS loader's own search path

## Usage

```ruby
require "htmlsanitizer"

s = HtmlSanitizer::Sanitizer.new
s.sanitize('<div onclick="alert(1)">Hello <script>evil()</script></div>')
# => "<div>Hello </div>"
s.close
```

Block form closes the native handle for you:

```ruby
HtmlSanitizer::Sanitizer.open do |s|
  s.allowed_tags.add("my-widget")
  s.sanitize("<my-widget>x</my-widget>")   # => "<my-widget>x</my-widget>"
end
```

One-shot module helpers:

```ruby
HtmlSanitizer.sanitize("<div>a<script>b</script></div>")   # => "<div>a</div>"
HtmlSanitizer.sanitize_document(html, "https://example.com/")
```

### Policy lists

Six `Enumerable` set-like views, each backed by the engine's own list:

```ruby
s.allowed_tags
s.allowed_attributes
s.allowed_css_properties
s.allowed_schemes
s.allowed_classes
s.uri_attributes
```

```ruby
s.allowed_tags.add("my-widget")        # or  s.allowed_tags << "my-widget"
s.allowed_tags.delete("div")
s.allowed_schemes.include?("http")     # => true
s.allowed_schemes.size                 # => 2
s.allowed_schemes.to_a.sort            # => ["http", "https"]
s.allowed_classes.clear
```

### Flags

```ruby
s.keep_child_nodes = true       # keep children of a removed element
s.allow_data_attributes = true  # let data-* through without listing each
```

### Callbacks

All seven hooks are supported. They take a block (or any callable) and return
`self`, so they chain. Pass `nil` to clear a hook.

For the `removing_*` family, **returning a truthy value CANCELS the removal**
(keeps the node/attribute/property):

```ruby
s.on_removing_tag       { |node, reason| node.name == "keep-me" }
s.on_removing_attribute { |elem, attr, reason| false }
s.on_removing_style     { |elem, name, value, reason| name == "-custom-thing" }
s.on_removing_comment   { |node| true }
s.on_post_process_node  { |node| ... }         # no return value
s.on_post_process_dom   { |document| ... }     # no return value
s.on_filter_url         { |elem, raw, resolved| resolved }   # "" drops the attribute
```

`on_filter_url` returns the URL to use. The returned String is copied into a C
buffer the engine takes ownership of — you do not free it.

### Node and Attribute

Callbacks receive `HtmlSanitizer::Node` / `HtmlSanitizer::Attribute` wrappers
over **borrowed** pointers. They are valid only for the duration of the
callback — the DOM is freed when `sanitize` returns, so do not retain one.

```ruby
node.kind        # 1=Document, 2=Element, 3=Text, 4=Comment
node.document? / node.element? / node.text? / node.comment?
node.name        # lowercased tag name ("" for non-elements)
node.value       # text/comment content
node.parent      # Node or nil
node.children    # [Node, ...]
node.attributes  # [Attribute, ...]

attr.name
attr.value
attr.value = "https://example.com/safe"   # rewrite in place
```

## Memory

Every `char*` the engine returns is caller-owned. `Native::Lib#take_string`
copies it into a Ruby String and frees it through
`aether_hs_embed_free_string` in an `ensure` block — leaking that buffer is the
single easiest mistake in any of these bindings, so all string reads go through
that one method.

Fiddle closures are held in the sanitizer's `@keepalive` array for as long as
the handle lives. A closure the GC collects while the engine can still call it
would crash the process.

`#close` frees the native handle; using the sanitizer afterwards raises
`HtmlSanitizer::ClosedError`. The block form closes for you.

## Tests

The 12-check conformance suite (`docs/conformance.md`) lives in
`spec/conformance_spec.rb`. Checks 10 and 11 — the callback trampoline and the
string-returning `on_filter_url` — are both implemented and passing; this
binding skips nothing.

```sh
aeb ruby/.tests.ae          # builds the engine first, then runs rspec
# or, with the engine already built:
HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so rspec
```

`rspec` is often a `--user-install` gem; `.tests.ae` prepends `Gem.user_dir/bin`
to `PATH` and invokes `ruby -S rspec` so no extra setup is needed.
