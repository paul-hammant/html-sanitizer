--- Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).
---
--- The idiomatic Lua surface over the HtmlSanitizer core. Carries no
--- sanitizer logic — every function here marshals to the C extension in
--- `htmlsanitizer_native` (lua/src/htmlsanitizer.c), which in turn calls the
--- `aether_hs_embed_*` ABI. One sanitizer core, one set of behaviours, N language
--- surfaces.
---
---     local hs = require("htmlsanitizer")
---     local s = hs.new()
---     print(s:sanitize('<div onclick="alert(1)">Hello</div>'))
---     -- <div>Hello</div>
---     s:close()

local native = require("htmlsanitizer_native")

local M = {}

-- ---- ABI constants, re-exported ----

--- Allow-list selectors.
M.TAGS           = native.TAGS
M.ATTRIBUTES     = native.ATTRIBUTES
M.CSS_PROPERTIES = native.CSS_PROPERTIES
M.SCHEMES        = native.SCHEMES
M.CLASSES        = native.CLASSES
M.URI_ATTRIBUTES = native.URI_ATTRIBUTES

--- Why the sanitizer core is about to remove something.
M.REASON_NOT_ALLOWED_TAG       = native.REASON_NOT_ALLOWED_TAG
M.REASON_NOT_ALLOWED_ATTRIBUTE = native.REASON_NOT_ALLOWED_ATTRIBUTE
M.REASON_NOT_ALLOWED_STYLE     = native.REASON_NOT_ALLOWED_STYLE
M.REASON_NOT_ALLOWED_URL_VALUE = native.REASON_NOT_ALLOWED_URL_VALUE
M.REASON_NOT_ALLOWED_VALUE     = native.REASON_NOT_ALLOWED_VALUE
M.REASON_NOT_ALLOWED_CSS_CLASS = native.REASON_NOT_ALLOWED_CSS_CLASS
M.REASON_CLASS_ATTRIBUTE_EMPTY = native.REASON_CLASS_ATTRIBUTE_EMPTY
M.REASON_STYLE_ATTRIBUTE_EMPTY = native.REASON_STYLE_ATTRIBUTE_EMPTY

--- Node kinds.
M.NODE_DOCUMENT = native.NODE_DOCUMENT
M.NODE_ELEMENT  = native.NODE_ELEMENT
M.NODE_TEXT     = native.NODE_TEXT
M.NODE_COMMENT  = native.NODE_COMMENT

-- ---- the allow-list view ----

--- A set-like view over one of the sanitizer core's six policy lists. Every operation
--- reads or writes the sanitizer core's own set — there is no Lua mirror to fall out
--- of sync.
local AllowList = {}
AllowList.__index = AllowList

local function new_allow_list(sanitizer, which)
  return setmetatable({ _s = sanitizer, _which = which }, AllowList)
end

--- Add one item (or every item of a table). Returns self, so calls chain.
function AllowList:add(item)
  if type(item) == "table" then
    for _, v in ipairs(item) do
      self._s._native:allow(self._which, v)
    end
  else
    self._s._native:allow(self._which, item)
  end
  return self
end

--- Remove one item — the "deny" direction. Returns self.
function AllowList:remove(item)
  self._s._native:disallow(self._which, item)
  return self
end

--- Empty the list. Returns self.
function AllowList:clear()
  self._s._native:clear(self._which)
  return self
end

--- Is `item` currently allowed?
function AllowList:contains(item)
  return self._s._native:is_allowed(self._which, item)
end

--- How many entries.
function AllowList:count()
  return self._s._native:count(self._which)
end

AllowList.__len = AllowList.count

--- The item at a 1-based `index`, or "" when out of range. (The ABI is
--- 0-based; the C extension does the conversion so Lua stays 1-based.)
function AllowList:at(index)
  return self._s._native:item_at(self._which, index)
end

--- The items, as a table, in the sanitizer core's own (unspecified but stable) order.
function AllowList:items()
  local out = {}
  for i = 1, self:count() do
    out[i] = self:at(i)
  end
  return out
end

--- The items, sorted — the deterministic version of `items()`.
function AllowList:sorted()
  local out = self:items()
  table.sort(out)
  return out
end

--- Iterate the items: `for item in list:iter() do ... end`
function AllowList:iter()
  local items, i = self:items(), 0
  return function()
    i = i + 1
    return items[i]
  end
end

function AllowList:__tostring()
  return "{" .. table.concat(self:sorted(), ", ") .. "}"
end

-- ---- node / attribute wrappers ----
--
-- The C extension already exposes Node and Attribute as userdata with methods
-- (`node:name()`, `attr:value()`), and stamps each with a generation counter
-- so a retained one errors rather than reading freed memory. They are handed
-- to callbacks unchanged — there is nothing useful for Lua to add, and
-- wrapping would only add a layer that could outlive the borrow.
--
-- Two conveniences that do not retain anything:

--- Every child of `node`, as a table.
function M.children(node)
  local out = {}
  for i = 1, node:child_count() do
    out[i] = node:child_at(i)
  end
  return out
end

--- Every attribute of `node`, as a table.
function M.attributes(node)
  local out = {}
  for i = 1, node:attr_count() do
    out[i] = node:attr_at(i)
  end
  return out
end

-- ---- the sanitizer ----

local Sanitizer = {}
Sanitizer.__index = Sanitizer

--- Create a sanitizer with the sanitizer core's secure defaults populated.
---
--- `native_lib` optionally overrides the library search, which otherwise is:
--- $HTMLSANITIZER_LIB, then `native/` and `../core/native/`, then the OS
--- loader's own path.
function M.new(native_lib)
  local self = setmetatable({}, Sanitizer)
  self._native = native.new(native_lib)
  self._closed = false

  self.allowed_tags           = new_allow_list(self, M.TAGS)
  self.allowed_attributes     = new_allow_list(self, M.ATTRIBUTES)
  self.allowed_css_properties = new_allow_list(self, M.CSS_PROPERTIES)
  self.allowed_schemes        = new_allow_list(self, M.SCHEMES)
  self.allowed_classes        = new_allow_list(self, M.CLASSES)
  self.uri_attributes         = new_allow_list(self, M.URI_ATTRIBUTES)
  return self
end

--- Release the native handle. Idempotent; the userdata's __gc is a backstop,
--- but closing deterministically is better.
function Sanitizer:close()
  if not self._closed then
    self._closed = true
    self._native:close()
  end
end

--- Run `body(s)` with a fresh sanitizer, closing it afterwards. Errors
--- propagate after the close.
function M.use(body, native_lib)
  local s = M.new(native_lib)
  local ok, res = pcall(body, s)
  s:close()
  if not ok then error(res, 0) end
  return res
end

--- Sanitize an HTML fragment. `base_url` resolves relative URLs; omit it (or
--- pass "") for no resolution.
function Sanitizer:sanitize(html, base_url)
  return self._native:sanitize(html, base_url or "")
end

--- Sanitize a full HTML document.
function Sanitizer:sanitize_document(html, base_url)
  return self._native:sanitize_document(html, base_url or "")
end

-- ---- flags ----

--- Keep the children of a removed element instead of dropping the subtree.
function Sanitizer:set_keep_child_nodes(on)
  self._native:set_keep_child_nodes(on and true or false)
  return self
end

function Sanitizer:get_keep_child_nodes()
  return self._native:get_keep_child_nodes()
end

--- Allow `data-*` attributes through without listing each one.
function Sanitizer:set_allow_data_attributes(on)
  self._native:set_allow_data_attributes(on and true or false)
  return self
end

function Sanitizer:get_allow_data_attributes()
  return self._native:get_allow_data_attributes()
end

--- The sanitizer core's ABI revision.
function Sanitizer:abi_version()
  return native.abi_version()
end

-- ---- callbacks ----
--
-- Each `on_*` takes a Lua function (or nil to clear the hook) and returns
-- self, so they chain. For the `removing_*` family, returning a truthy value
-- from your handler CANCELS the removal (keeps the node/attribute/property).
--
-- Handlers are anchored in the Lua registry by the C extension for as long as
-- the sanitizer core can call them, so a local function passed here is safe from
-- collection.

--- `handler(node, reason)` — return true to KEEP the tag.
function Sanitizer:on_removing_tag(handler)
  self._native:on_removing_tag(handler)
  return self
end

--- `handler(elem, attr, reason)` — return true to KEEP the attribute.
function Sanitizer:on_removing_attribute(handler)
  self._native:on_removing_attribute(handler)
  return self
end

--- `handler(elem, name, value, reason)` — return true to KEEP the property.
function Sanitizer:on_removing_style(handler)
  self._native:on_removing_style(handler)
  return self
end

--- `handler(node)` — return true to KEEP the comment.
function Sanitizer:on_removing_comment(handler)
  self._native:on_removing_comment(handler)
  return self
end

--- `handler(node)` — called for each node after it has been filtered.
function Sanitizer:on_post_process_node(handler)
  self._native:on_post_process_node(handler)
  return self
end

--- `handler(doc)` — called once with the whole document after filtering.
function Sanitizer:on_post_process_dom(handler)
  self._native:on_post_process_dom(handler)
  return self
end

--- `handler(elem, raw, resolved) -> string` — return the URL to use;
--- `resolved` unchanged for no rewrite, `""` to drop the attribute.
---
--- The returned string is copied into a malloc'd C buffer the sanitizer core takes
--- ownership of; you do not free it.
function Sanitizer:on_filter_url(handler)
  self._native:on_filter_url(handler)
  return self
end

-- ---- introspection / one-shots ----

--- The sanitizer core's ABI revision, without needing a sanitizer.
function M.abi_version()
  return native.abi_version()
end

--- Where the sanitizer core `.so` was actually loaded from.
function M.engine_path()
  return native.engine_path()
end

--- One-shot: sanitize `html` with the sanitizer core's defaults.
function M.sanitize(html, base_url)
  return M.use(function(s) return s:sanitize(html, base_url) end)
end

--- One-shot: sanitize `html` as a full document, with the sanitizer core's defaults.
function M.sanitize_document(html, base_url)
  return M.use(function(s) return s:sanitize_document(html, base_url) end)
end

M.Sanitizer = Sanitizer
M.AllowList = AllowList

return M
