-- A short tour of the Lua binding. Run it with the engine built:
--
--   cd core && ae build --emit=lib embed.ae --extra _embed_support.c \
--       -o native/libhtmlsanitizer.so
--   cd ../lua && ./build.sh
--   LUA_CPATH="./?.so;;" LUA_PATH="./src/?.lua;;" lua5.4 example/main.lua

local hs = require("htmlsanitizer")

print(string.format("engine: %s (ABI v%d)", hs.engine_path(), hs.abi_version()))

local s = hs.new()

-- 1. the defaults
print(s:sanitize('<div onclick="evil()">Hello <script>x</script></div>'))
-- <div>Hello </div>

-- 2. teach it a custom element
s.allowed_tags:add("my-widget")
print(s:sanitize("<my-widget>ok</my-widget>"))
-- <my-widget>ok</my-widget>

-- 3. keep the children of anything it removes
s:set_keep_child_nodes(true)
print(s:sanitize("<div><nope>Hello <span>world</span></nope></div>"))
-- <div>Hello <span>world</span></div>

-- 4. rewrite URLs as they are resolved
s:on_filter_url(function(_elem, _raw, resolved)
  return (resolved:gsub("^https://example%.com/", "https://cdn.example.net/"))
end)
print(s:sanitize('<img src="logo.png">', "https://example.com/"))
-- <img src="https://cdn.example.net/logo.png">

-- 5. veto a removal — a truthy return KEEPS the node
s:on_removing_tag(function(node, _reason) return node:name() == "keep-me" end)
print(s:sanitize("<div><keep-me>a</keep-me></div>"))
-- <div><keep-me>a</keep-me></div>

-- 6. inspect the policy
print("schemes: " .. tostring(s.allowed_schemes))
print("tags: " .. s.allowed_tags:count())

s:close()

-- 7. one-shots, for when a handle is overkill
print(hs.sanitize("<p>hi<script>no</script></p>"))
