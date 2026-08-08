-- LuaRocks manifest for the HtmlSanitizer Lua binding.
--
--   luarocks make htmlsanitizer-0.1.0-1.rockspec
--
-- The C extension `dlopen`s the shared engine at runtime rather than linking
-- it, so this rock has no external build dependency beyond Lua's own headers.
-- The engine must be findable at run time: set $HTMLSANITIZER_LIB, or install
-- libhtmlsanitizer.so somewhere the OS loader looks.

package = "htmlsanitizer"
version = "0.1.0-1"

source = {
  url = "git+https://github.com/paulhammant/html-sanitizer.git",
  dir = "html-sanitizer/lua",
}

description = {
  summary = "Clean HTML of constructs that can lead to XSS.",
  detailed = [[
    A thin Lua 5.4 C-extension binding over the shared HtmlSanitizer native
    engine (compiled from pure Aether). No sanitizer logic lives in Lua or in
    the extension — every call marshals to an aether_hs_embed_* symbol.
  ]],
  homepage = "https://github.com/paulhammant/html-sanitizer",
  license = "MIT",
}

dependencies = {
  -- lua_newuserdatauv and luaL_setmetatable's 5.4 semantics.
  "lua >= 5.4",
}

build = {
  type = "builtin",
  modules = {
    -- The idiomatic surface.
    htmlsanitizer = "src/htmlsanitizer.lua",
    -- The C extension it requires. `-ldl` for dlopen; the extension must NOT
    -- link liblua (the host interpreter supplies those symbols).
    htmlsanitizer_native = {
      sources = { "src/htmlsanitizer.c" },
      libraries = { "dl" },
    },
  },
}
