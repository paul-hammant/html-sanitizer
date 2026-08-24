# htmlsanitizer (Go)

Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).

This package is a **thin cgo binding** over the monorepo's one shared native
engine — `core/native/libhtmlsanitizer.so`, compiled from pure Aether. It
contains **no sanitizer logic**: every method marshals to an
`aether_hs_embed_*` call. One engine, one set of behaviours, N language
surfaces.

## Building

Unlike the dlopen-based bindings (Python/ctypes, Ruby/Fiddle), cgo **links**
the engine, so the shared library must exist at *build* time as well as run
time. Build it first:

```sh
cd core && ae build --emit=lib embed.ae --extra _embed_support.c \
    -o native/libhtmlsanitizer.so
```

The `#cgo LDFLAGS` in `htmlsanitizer.go` search both `go/native` and
`../core/native`, and bake the same two directories in as `rpath`, so an
in-tree `go build ./...` needs no further setup:

```
-L${SRCDIR}/native -L${SRCDIR}/../core/native -lhtmlsanitizer
-Wl,-rpath,${SRCDIR}/native -Wl,-rpath,${SRCDIR}/../core/native
```

For a distributable build, copy the engine into `go/native/` (which
`.tests.ae` does automatically) so the rpath resolves without the monorepo
layout around it.

## Usage

```go
import "github.com/paul-hammant/html-sanitizer/go"

s, err := htmlsanitizer.New()
if err != nil {
    log.Fatal(err)
}
defer s.Close()

clean := s.Sanitize(`<div onclick="alert(1)">Hello <script>evil()</script></div>`, "")
// clean == "<div>Hello </div>"
```

The second argument is the base URL used to resolve relative URLs; pass `""`
for no resolution.

Package-level one-shots create and release a handle around the call:

```go
clean, err := htmlsanitizer.Sanitize("<div>a<script>b</script></div>", "")
clean, err := htmlsanitizer.SanitizeDocument(html, "https://example.com/")
```

`Sanitize` returns `""` on a closed sanitizer; use `SanitizeErr` if you need
that distinguished from a legitimately empty result — it returns `ErrClosed`.

### Policy lists

Six set-like views, each backed by the engine's own list:

```go
s.AllowedTags
s.AllowedAttributes
s.AllowedCSSProperties
s.AllowedSchemes
s.AllowedClasses
s.URIAttributes
```

```go
s.AllowedTags.Add("my-widget", "my-other-widget")
s.AllowedTags.Remove("div")
s.AllowedSchemes.Contains("http")   // true
s.AllowedSchemes.Len()              // 2
s.AllowedSchemes.Sorted()           // []string{"http", "https"}
s.AllowedClasses.Clear()
```

`Items()` enumerates in the engine's own (unspecified but stable) order;
`Sorted()` is the deterministic version.

### Flags

```go
s.SetKeepChildNodes(true)       // keep children of a removed element
s.SetAllowDataAttributes(true)  // let data-* through without listing each
```

### Callbacks

All seven hooks are supported. Each `On*` returns the `*Sanitizer`, so they
chain; passing `nil` clears a hook.

For the `Removing*` family, **returning true CANCELS the removal** (keeps the
node/attribute/property):

```go
s.OnRemovingTag(func(node htmlsanitizer.Node, r htmlsanitizer.Reason) bool {
    return node.Name() == "keep-me"
})
s.OnRemovingAttribute(func(elem htmlsanitizer.Node, attr htmlsanitizer.Attribute, r htmlsanitizer.Reason) bool {
    return false
})
s.OnRemovingStyle(func(elem htmlsanitizer.Node, name, value string, r htmlsanitizer.Reason) bool {
    return name == "-custom-thing"
})
s.OnRemovingComment(func(node htmlsanitizer.Node) bool { return true })
s.OnPostProcessNode(func(node htmlsanitizer.Node) { ... })
s.OnPostProcessDOM(func(doc htmlsanitizer.Node) { ... })
s.OnFilterURL(func(elem htmlsanitizer.Node, raw, resolved string) string {
    return resolved   // "" drops the attribute
})
```

`OnFilterURL` returns the URL to use. The string is copied into a malloc'd C
buffer the engine takes ownership of — you do not free it.

### Node and Attribute

Callbacks receive `Node` / `Attribute` values wrapping **borrowed** pointers,
valid only for the duration of the callback. The DOM is freed when `Sanitize`
returns, so do not retain one.

```go
node.Kind()        // KindDocument | KindElement | KindText | KindComment
node.Name()        // lowercased tag name ("" for non-elements)
node.Value()       // text/comment content
node.Parent()      // (Node, bool)
node.Children()    // []Node
node.Attributes()  // []Attribute

attr.Name()
attr.Value()
attr.SetValue("https://example.com/safe")   // rewrite in place
```

## How the cgo callback bridge works

cgo forbids passing a Go pointer to C and cannot hand C the address of a Go
func. The binding therefore uses the standard pattern:

- `bridge.h` declares seven plain C functions (`hsgo_removing_tag`, …).
- `bridge.go` defines them as `//export`-ed Go functions, so cgo emits a real
  C symbol for each. Those symbols are what get registered with the engine.
- Each trampoline receives the ABI's opaque `user_data` first. That pointer is
  a small **malloc'd cell holding a `runtime/cgo.Handle`** token — an integer
  registry key, never a pointer into the Go heap.

The cell matters: the tempting `unsafe.Pointer(uintptr(handle))` is invalid Go
(integer-to-pointer arithmetic) and aborts the process under `-race` /
`-d=checkptr`. Keeping the token in C memory keeps the `void*` a genuine C
pointer and every Go pointer on the Go side.

Registered hooks are stored on the `*Sanitizer` — the Go equivalent of the
other bindings' keepalive list — and cleared by `Close`.

## Memory

Every `char*` the engine returns is caller-owned. `takeString` copies it into
a Go string and frees it through `aether_hs_embed_free_string` in a `defer`;
every string result in the package goes through that one function.

`Close` frees the native handle, deletes the `cgo.Handle`, and frees the
`user_data` cell. It is idempotent. A finalizer is installed as a backstop for
a dropped sanitizer, but `defer s.Close()` remains the deterministic way.

A `*Sanitizer` is **not** safe for concurrent use — the native handle carries
mutable policy and hook state. Use one per goroutine, or guard it.

## Tests

The 12-check conformance suite (`docs/conformance.md`) lives in
`htmlsanitizer_test.go`. Checks 10 and 11 — the callback trampoline and the
string-returning `OnFilterURL` — are both implemented and passing; this
binding skips nothing.

```sh
aeb go/.tests.ae     # builds the engine, stages it into go/native, runs go test
# or, with the engine already built:
go test ./...
go test -race ./...  # also exercises checkptr on the user_data cell
```
