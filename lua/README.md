# htmlsanitizer (Lua)

Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).

This binding is a **thin Lua 5.4 C extension** over the monorepo's one shared
native sanitizer core — `core/native/libhtmlsanitizer.so`, compiled from pure Aether.
It contains **no sanitizer logic**: every call marshals to an
`aether_hs_embed_*` symbol. One sanitizer core, one set of behaviours, N language
surfaces.

Two files make up the binding:

| File | Role |
|---|---|
| `src/htmlsanitizer.c` | the C extension — the **only** place that knows the ABI |
| `src/htmlsanitizer.lua` | the idiomatic Lua surface over it |

## Why a C extension and not FFI

Standard Lua 5.4 has no FFI. LuaJIT's `ffi` library is not Lua 5.4 and would
pin the binding to a fork stuck at 5.1 semantics. So this binding does what
Lua bindings normally do: a small C extension.

It still **`dlopen`s** the sanitizer core rather than linking it, so the same
`HTMLSANITIZER_LIB` resolution every other binding uses applies here, and one
sanitizer core `.so` serves them all.

## Building

```sh
cd core && ae build --emit=lib embed.ae --extra _embed_support.c \
    -o native/libhtmlsanitizer.so
cd ../lua && ./build.sh
```

`build.sh` produces `htmlsanitizer_native.so`. It finds Lua's headers via
`pkg-config lua5.4` (falling back to `/usr/include/lua5.4` and
`/usr/local/include`), and — as a Lua C extension must — links **`-ldl` but
not liblua**: the host interpreter already provides the Lua symbols, and
linking a second copy is the classic "two Lua VMs in one process" crash.

Or with LuaRocks:

```sh
luarocks make htmlsanitizer-0.1.0-1.rockspec
```

### The bundled `lua54` host

Debian 12 (and some others) ship `liblua5.4-dev` — headers and shared
library — but package **`lua5.3`** as the interpreter. A 5.3 interpreter
cannot load a 5.4 extension (`undefined symbol: lua_newuserdatauv`), so on
such a box there is nothing to test against.

Rather than skip, `build.sh` compiles `host/lua54.c` — about forty lines that
call `luaL_newstate` / `luaL_openlibs` / `luaL_dofile` — into `./lua54`, and
`run_tests.sh` uses it. This is **test scaffolding only**: the extension
itself loads into any real Lua 5.4 host. When a `lua5.4` binary *is* on
`PATH`, `build.sh` skips this step entirely.

### Library resolution

In order:

1. an explicit path — `hs.new("/path/to/libhtmlsanitizer.so")`
2. `$HTMLSANITIZER_LIB` (what the in-tree `.tests.ae` leaf sets)
3. `native/libhtmlsanitizer.so`, then `../core/native/libhtmlsanitizer.so`
4. the OS loader's own search path

`hs.engine_path()` reports which one actually loaded.

## Usage

```lua
local hs = require("htmlsanitizer")

local s = hs.new()
print(s:sanitize('<div onclick="alert(1)">Hello <script>x</script></div>'))
-- <div>Hello </div>
s:close()
```

The second argument is the base URL used to resolve relative URLs; omit it
(or pass `""`) for no resolution.

`hs.use` is the scoped form — it closes the sanitizer even if `body` errors —
and there are one-shots that create and release a handle around the call:

```lua
hs.use(function(s) return s:sanitize(html) end)

hs.sanitize('<div>a<script>b</script></div>')
hs.sanitize_document(html, "https://example.com/")
```

Using a closed sanitizer raises an error. `close()` is idempotent, and the
userdata's `__gc` is a backstop for a dropped handle — but closing
deterministically is better.

### Policy lists

Six set-like views, each backed by the sanitizer core's own list — there is no Lua
mirror to fall out of sync:

```lua
s.allowed_tags
s.allowed_attributes
s.allowed_css_properties
s.allowed_schemes
s.allowed_classes
s.uri_attributes
```

```lua
s.allowed_tags:add("my-widget"):add("my-other-widget")
s.allowed_tags:add({ "a", "b" })     -- a table adds each item
s.allowed_tags:remove("div")
s.allowed_schemes:contains("http")   -- true
s.allowed_schemes:count()            -- 2   (also #s.allowed_schemes)
s.allowed_schemes:sorted()           -- { "http", "https" }
s.allowed_schemes:at(1)              -- "http"  (1-based, like all of Lua)
for scheme in s.allowed_schemes:iter() do print(scheme) end
s.allowed_classes:clear()
```

`items()` enumerates in the sanitizer core's own (unspecified but stable) order;
`sorted()` is the deterministic version. Indices are **1-based** throughout —
the C extension converts to the ABI's 0-based indexing so the Lua surface
never sees it.

### Flags

```lua
s:set_keep_child_nodes(true)       -- keep children of a removed element
s:set_allow_data_attributes(true)  -- let data-* through without listing each
s:get_keep_child_nodes()           -- true
```

### Callbacks

All seven hooks are supported. Each `on_*` returns the sanitizer, so they
chain; passing `nil` clears a hook.

For the `removing_*` family, **a truthy return CANCELS the removal** (keeps
the node/attribute/property):

```lua
s:on_removing_tag(function(node, reason) return node:name() == "keep-me" end)
s:on_removing_attribute(function(elem, attr, reason) return false end)
s:on_removing_style(function(elem, name, value, reason)
  return name == "-custom-thing"
end)
s:on_removing_comment(function(node) return true end)
s:on_post_process_node(function(node) --[[ ... ]] end)
s:on_post_process_dom(function(doc) --[[ ... ]] end)
s:on_filter_url(function(elem, raw, resolved) return resolved end)  -- "" drops it
```

`on_filter_url` returns the URL to use. The string is `strdup`'d into a buffer
the sanitizer core takes ownership of — you do not free it.

### Node and Attribute

Callbacks receive `Node` / `Attribute` userdata wrapping **borrowed**
pointers, valid only for the duration of that callback.

```lua
node:kind()         -- hs.NODE_DOCUMENT | NODE_ELEMENT | NODE_TEXT | NODE_COMMENT
node:name()         -- lowercased tag name ("" for non-elements)
node:value()        -- text/comment content
node:parent()       -- Node or nil
node:child_count()
node:child_at(i)    -- 1-based
node:attr_count()
node:attr_at(i)     -- 1-based
hs.children(node)   -- all children as a table
hs.attributes(node) -- all attributes as a table

attr:name()
attr:value()
attr:set_value("https://example.com/safe")   -- rewrite in place
```

`attr:set_value` is safe with Lua's own (collectable) string buffer:
`aether_hs_embed_attr_set_value` **copies** its argument core-side.

**Retained nodes error rather than crash.** Every `Node`/`Attribute` is
stamped with a generation counter that the extension bumps when `sanitize`
returns. Using one afterwards — the classic binding bug, and a
use-after-free in most languages — raises a clear Lua error instead:

```lua
local escaped
s:on_post_process_dom(function(doc) escaped = doc end)
s:sanitize("<div>a</div>")
escaped:name()   --> error: ... borrowed for the duration of a callback and
                 --          is no longer valid ...
```

## How the callback bridge works

The C extension registers seven plain C trampolines with the sanitizer core and passes
the `Sanitizer*` userdata as the ABI's opaque **`user_data`** — the pointer
handed back as each callback's *first* argument. From it a trampoline recovers
the `lua_State` and the handler table.

Two details are load-bearing:

- **Keepalive.** Each sanitizer owns a table of Lua handler functions anchored
  in `LUA_REGISTRYINDEX` (via `luaL_ref`), so a handler cannot be collected
  while the sanitizer core can still call it. `close()` unrefs it. This is the Lua
  equivalent of ctypes' keepalive list.
- **No `longjmp` across C frames.** A Lua error inside a handler must not
  unwind through the sanitizer core's stack, so every trampoline invokes the handler
  with `lua_pcall`. On error it prints to stderr and returns the **safe
  default**: `0` for the `removing_*` family (let the removal proceed) and the
  unmodified `resolved` pointer for `filter_url` (no rewrite). A broken
  handler therefore fails *closed*, never leaving a disallowed tag in place.

Integer arguments are declared `int`, matching the ABI; declaring `long`
would give a 4-vs-8-byte mismatch on LP64 and garbage `reason` values.

`sanitize()` also guards against re-entry from inside a callback — the sanitizer core
holds a half-built DOM at that point — and raises instead.

## Memory

Every `char*` the sanitizer core returns is caller-owned. `push_owned()` is the single
place a returned string becomes a Lua string, and it always calls
`aether_hs_embed_free_string`. Borrowed `const char*` **arguments** (the
`name`/`value`/`raw`/`resolved` callback parameters) are copied with
`lua_pushstring` and never freed — the sanitizer core owns those.

Strings handed *to* the sanitizer core are Lua's own buffers, valid for the duration
of the call. The one exception is `on_filter_url`'s return value, which is
`strdup`'d precisely because the sanitizer core frees it.

A sanitizer is **not** safe for concurrent use across coroutines that could
interleave a `sanitize` call, and the trampolines assume the `lua_State` that
created the sanitizer. Use one per state.

### A note on RSS growth (not this binding)

Repeated `sanitize()` calls grow RSS by roughly 0.2–0.3 kB per call. That is
**core-side**, not a binding leak — it is the `heap.free` / nested-string
refcount caveat described in the root `README.md`. Measured over 50,000
identical calls on this checkout:

| Harness | RSS delta |
|---|---|
| pure C (dlopen + the ABI, no binding) | 4100 kB |
| this Lua binding | 3912 kB |

The Lua path grows *less* than raw C for the same workload, because Lua's GC
reclaims the wrapper objects the binding allocates. In other words the binding
adds nothing of its own: every returned `char*` is being freed. Long-lived
processes sanitizing untrusted input in a loop should be aware of the sanitizer core
behaviour regardless of which binding they use.

## Tests

The 12-check conformance suite (`docs/conformance.md`) lives in
`test/conformance.lua`, alongside extras covering the remaining callback
shapes, the generation guard, and the closed-handle error. Lua 5.4 ships no
de-facto-standard test framework, so it is a **plain assertion runner** — no
dependency to install, and the exit code is the result.

Checks 10 and 11 — the callback trampoline and the string-returning
`on_filter_url` — are both implemented and passing; this binding skips
nothing.

```sh
aeb lua/.tests.ae     # builds the sanitizer core + extension, then runs the suite
# or, with the sanitizer core already built:
HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so ./run_tests.sh
```

`.tests.ae` skips (exit 0, with a clear `lua: SKIPPED` line) when there is no
C compiler or no Lua 5.4 headers — rather than failing the build DAG for a
missing toolchain.
