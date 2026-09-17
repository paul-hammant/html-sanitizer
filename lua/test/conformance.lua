--- The 12-check binding conformance suite (docs/conformance.md).
---
--- Proves the Lua binding marshals every value shape across the FFI. It is
--- NOT a sanitizer test suite — the behavioural cases live in the sanitizer core's own
--- tests and run once, in Aether.
---
--- Lua 5.4 has no de-facto-standard test framework in its distribution, so
--- this is a plain assertion runner: no dependency to install, and the exit
--- code is the result. Run it with `lua/run_tests.sh`, or:
---
---     lua5.4 -e 'package.cpath="./?.so;"..package.cpath' \
---            -e 'package.path="./src/?.lua;"..package.path' \
---            test/conformance.lua

local hs = require("htmlsanitizer")

-- ---- a minimal test harness ----

local passed, failed = 0, 0
local failures = {}

local function record_failure(name, detail)
  failed = failed + 1
  failures[#failures + 1] = name .. "\n      " .. detail
  print(string.format("  FAIL %s\n      %s", name, detail))
end

local function test(name, body)
  local s = hs.new()
  local ok, err = pcall(body, s)
  s:close()
  if ok then
    passed = passed + 1
    print("  PASS " .. name)
  else
    record_failure(name, tostring(err))
  end
end

local function eq(got, want, what)
  if got ~= want then
    error(string.format("%s:\n        got  %q\n        want %q",
      what or "value", tostring(got), tostring(want)), 2)
  end
end

local function is_true(got, what)
  if not got then error((what or "value") .. ": expected true, got " ..
    tostring(got), 2) end
end

local function is_false(got, what)
  if got then error((what or "value") .. ": expected false, got " ..
    tostring(got), 2) end
end

local function contains(list, want, what)
  for _, v in ipairs(list) do
    if v == want then return end
  end
  error(string.format("%s: %q not found in {%s}", what or "list",
    tostring(want), table.concat(list, ", ")), 2)
end

print("=== htmlsanitizer Lua binding conformance ===")
print(string.format("sanitizer core: %s (ABI v%d)", hs.engine_path(), hs.abi_version()))

-- ---- the twelve ----

test("01 script removed", function(s)
  eq(s:sanitize("<div>Hello <script>alert(1)</script> world!</div>"),
     "<div>Hello  world!</div>")
end)

test("02 onclick removed", function(s)
  eq(s:sanitize('<div onclick="alert(1)">Hello</div>'), "<div>Hello</div>")
end)

test("03 empty string", function(s)
  eq(s:sanitize(""), "")
end)

test("04 utf-8 round trip", function(s)
  -- Lua strings are byte strings; this proves the bytes survive intact rather
  -- than being mangled by a Latin-1 assumption anywhere in the chain.
  eq(s:sanitize("<div>café ☕</div>"), "<div>café ☕</div>")
end)

test("05 allow custom tag", function(s)
  eq(s:sanitize("<my-widget>x</my-widget>"), "")
  s.allowed_tags:add("my-widget")
  eq(s:sanitize("<my-widget>x</my-widget>"), "<my-widget>x</my-widget>")
end)

test("06 disallow tag", function(s)
  eq(s:sanitize("<div>x</div>"), "<div>x</div>")
  s.allowed_tags:remove("div")
  eq(s:sanitize("<div>x</div>"), "")
end)

test("07 membership and count", function(s)
  is_true(s.allowed_schemes:contains("http"), "http allowed")
  is_false(s.allowed_schemes:contains("gopher"), "gopher allowed")
  eq(s.allowed_schemes:count(), 2, "scheme count")
  eq(#s.allowed_schemes, 2, "scheme count via __len")
end)

test("08 enumeration", function(s)
  local got = s.allowed_schemes:sorted()
  eq(#got, 2, "enumerated count")
  eq(got[1], "http")
  eq(got[2], "https")
end)

test("09 keep child nodes", function(s)
  eq(s:sanitize("<div><nope>Hello <span>world</span></nope></div>"),
     "<div></div>")
  s:set_keep_child_nodes(true)
  is_true(s:get_keep_child_nodes(), "keep_child_nodes")
  eq(s:sanitize("<div><nope>Hello <span>world</span></nope></div>"),
     "<div>Hello <span>world</span></div>")
end)

test("10 on_removing_tag cancels", function(s)
  local names, reasons = {}, {}
  s:on_removing_tag(function(node, reason)
    names[#names + 1] = node:name()
    reasons[#reasons + 1] = reason
    return node:name() == "keep-me"
  end)
  eq(s:sanitize("<div><keep-me>a</keep-me><drop-me>b</drop-me></div>"),
     "<div><keep-me>a</keep-me></div>")
  contains(names, "keep-me", "hook saw keep-me")
  contains(names, "drop-me", "hook saw drop-me")
  eq(reasons[1], hs.REASON_NOT_ALLOWED_TAG, "reason is an int, not garbage")
end)

test("11 on_filter_url rewrites", function(s)
  s:on_filter_url(function(_elem, _raw, resolved)
    if resolved == "https://example.com/logo.png" then
      return "https://cdn.example.net/logo.png"
    end
    return resolved
  end)
  eq(s:sanitize('<img src="logo.png">', "https://example.com"),
     '<img src="https://cdn.example.net/logo.png">')
end)

test("12 handles are independent", function()
  local a, b = hs.new(), hs.new()
  a.allowed_tags:add("only-in-a")
  is_true(a.allowed_tags:contains("only-in-a"), "a knows the tag")
  is_false(b.allowed_tags:contains("only-in-a"), "b does not")
  a:close()
  b:close()
end)

-- ---- a few extras that exercise the remaining callback shapes ----

test("on_removing_attribute sees the attribute", function(s)
  local seen = {}
  s:on_removing_attribute(function(elem, attr, _reason)
    seen[#seen + 1] = elem:name() .. "/" .. attr:name() .. "/" .. attr:value()
    return false
  end)
  eq(s:sanitize('<div onclick="alert(1)">x</div>'), "<div>x</div>")
  contains(seen, "div/onclick/alert(1)", "attribute hook")
end)

test("on_removing_comment cancels", function(s)
  s:on_removing_comment(function(_node) return true end)
  eq(s:sanitize("<div>a<!-- keep -->b</div>"), "<div>a<!-- keep -->b</div>")
end)

test("on_removing_style is four-arg", function(s)
  local seen = {}
  s:on_removing_style(function(_elem, name, value, _reason)
    seen[#seen + 1] = name .. "=" .. value
    return name == "-custom-thing"
  end)
  local out = s:sanitize('<div style="-custom-thing: 3; color: red">x</div>')
  is_true(out:find("-custom-thing", 1, true) ~= nil, "custom property kept")
  contains(seen, "-custom-thing=3", "style hook args")
end)

test("post_process_node visits", function(s)
  local kinds = {}
  s:on_post_process_node(function(node) kinds[#kinds + 1] = node:kind() end)
  s:sanitize("<div><span>a</span><span>b</span></div>")
  is_true(#kinds > 0, "post_process_node fired")
end)

test("node tree navigation", function(s)
  local kind, children
  s:on_post_process_dom(function(doc)
    kind = doc:kind()
    children = doc:child_count()
    -- walk one level, proving child_at/parent are wired
    if children > 0 then
      local first = doc:child_at(1)
      assert(first ~= nil, "child_at(1) returned nil")
      assert(first:parent() ~= nil, "parent() returned nil")
    end
  end)
  s:sanitize("<div>a</div><p>b</p>")
  eq(kind, hs.NODE_DOCUMENT, "document kind")
  is_true(children >= 2, "document has >= 2 children")
end)

test("attr_set_value rewrites in place", function(s)
  s:on_removing_attribute(function(_elem, attr, _reason)
    if attr:name() == "onclick" then
      attr:set_value("sanitised")
      eq(attr:value(), "sanitised", "value after set_value")
    end
    return false
  end)
  eq(s:sanitize('<div onclick="alert(1)">x</div>'), "<div>x</div>")
end)

test("attributes helper enumerates", function(s)
  local names = {}
  s:on_post_process_node(function(node)
    if node:kind() == hs.NODE_ELEMENT and node:name() == "a" then
      for _, a in ipairs(hs.attributes(node)) do
        names[#names + 1] = a:name()
      end
    end
  end)
  s:sanitize('<a href="https://example.com/" title="t">x</a>')
  contains(names, "href", "href seen")
  contains(names, "title", "title seen")
end)

test("clearing a hook restores default behaviour", function(s)
  s:on_removing_tag(function(node, _r) return node:name() == "keep-me" end)
  eq(s:sanitize("<div><keep-me>a</keep-me></div>"),
     "<div><keep-me>a</keep-me></div>")
  s:on_removing_tag(nil)
  eq(s:sanitize("<div><keep-me>a</keep-me></div>"), "<div></div>")
end)

test("sanitize_document is wired", function(s)
  eq(s:sanitize_document("<div>doc<script>x</script></div>"), "<html><head></head><body><div>doc</div></body></html>")
end)

test("allow_data_attributes flag", function(s)
  is_false(s:get_allow_data_attributes(), "off by default")
  s:set_allow_data_attributes(true)
  is_true(s:get_allow_data_attributes(), "on after set")
  eq(s:sanitize('<div data-x="1"></div>'), '<div data-x="1"></div>')
end)

test("clear empties a policy list", function(s)
  s.allowed_schemes:clear()
  eq(s.allowed_schemes:count(), 0, "count after clear")
end)

test("item_at out of range is an empty string", function(s)
  eq(s.allowed_schemes:at(999), "", "out of range")
  eq(s.allowed_schemes:at(0), "", "below range (1-based)")
end)

test("abi version", function(s)
  is_true(s:abi_version() >= 1, "abi_version >= 1")
end)

test("closed sanitizer rejects use", function()
  local s = hs.new()
  s:close()
  local ok, err = pcall(function() return s:sanitize("<div>x</div>") end)
  is_false(ok, "sanitize on a closed handle")
  is_true(tostring(err):find("closed", 1, true) ~= nil,
    "error mentions 'closed': " .. tostring(err))
  s:close() -- idempotent
end)

test("a retained node errors instead of reading freed memory", function(s)
  local escaped
  s:on_post_process_dom(function(doc) escaped = doc end)
  s:sanitize("<div>a</div>")
  is_true(escaped ~= nil, "captured a node")
  local ok, err = pcall(function() return escaped:name() end)
  is_false(ok, "using a node after sanitize() returned")
  is_true(tostring(err):find("no longer valid", 1, true) ~= nil,
    "error explains the borrow: " .. tostring(err))
end)

test("one-shot helpers", function()
  eq(hs.sanitize("<div>a<script>b</script></div>"), "<div>a</div>")
  eq(hs.sanitize_document("<div>a<script>b</script></div>"), "<html><head></head><body><div>a</div></body></html>")
end)

-- ---- result ----

print(string.format("=== %d passed, %d failed ===", passed, failed))
if failed > 0 then
  print("failures:")
  for _, f in ipairs(failures) do print("  - " .. f) end
  os.exit(1)
end
os.exit(0)
