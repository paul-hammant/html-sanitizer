#!/bin/sh
# Build the extension and run the conformance suite.
#
#   HTMLSANITIZER_LIB=/path/to/libhtmlsanitizer.so ./run_tests.sh
#
# Exits 0 on success, 1 on a test failure, 2 when the toolchain is missing.
set -e

cd "$(dirname "$0")"

./build.sh

# Prefer a real distro interpreter; fall back to the host build.sh made.
if command -v lua5.4 >/dev/null 2>&1; then
    LUA=lua5.4
elif command -v lua >/dev/null 2>&1 && lua -v 2>&1 | grep -q "Lua 5.4"; then
    LUA=lua
elif [ -x ./lua54 ]; then
    LUA=./lua54
    echo "lua: using the bundled ./lua54 host (no lua5.4 binary on PATH)"
else
    echo "lua: no Lua 5.4 interpreter available" >&2
    exit 2
fi

# ?.so finds htmlsanitizer_native.so here; ?.lua finds src/htmlsanitizer.lua.
LUA_CPATH="./?.so;${LUA_CPATH:-;}" \
LUA_PATH="./src/?.lua;${LUA_PATH:-;}" \
    "$LUA" test/conformance.lua
