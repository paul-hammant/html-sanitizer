#!/bin/sh
# Build the Lua 5.4 C extension (htmlsanitizer_native.so) for this binding.
#
# The extension `dlopen`s the engine at runtime rather than linking it, so the
# engine .so does NOT need to exist to build this — only to run it.
#
# Outputs, in lua/:
#   htmlsanitizer_native.so   the C extension Lua `require`s
#   lua54                     a minimal Lua 5.4 host (only if no lua5.4 binary
#                             is on PATH; see the note in run_tests.sh)
set -e

cd "$(dirname "$0")"

CC="${CC:-cc}"
CFLAGS="${CFLAGS:--O2 -fPIC -Wall -Wextra}"

# Find Lua 5.4's headers. pkg-config is authoritative; fall back to the usual
# Debian/Homebrew locations.
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists lua5.4; then
    LUA_CFLAGS="$(pkg-config --cflags lua5.4)"
    LUA_LIBS="$(pkg-config --libs lua5.4)"
elif command -v pkg-config >/dev/null 2>&1 && pkg-config --exists lua-5.4; then
    LUA_CFLAGS="$(pkg-config --cflags lua-5.4)"
    LUA_LIBS="$(pkg-config --libs lua-5.4)"
elif [ -f /usr/include/lua5.4/lua.h ]; then
    LUA_CFLAGS="-I/usr/include/lua5.4"
    LUA_LIBS="-llua5.4"
elif [ -f /usr/local/include/lua.h ]; then
    LUA_CFLAGS="-I/usr/local/include"
    LUA_LIBS="-llua"
else
    echo "lua: cannot find Lua 5.4 headers (install liblua5.4-dev)" >&2
    exit 2
fi

# The extension itself. A Lua C extension must NOT link liblua — the host
# interpreter already provides those symbols, and linking a second copy is a
# classic source of "multiple Lua VMs" crashes. Hence LUA_CFLAGS but no
# LUA_LIBS here.
UNAME="$(uname -s)"
SHARED="-shared"
if [ "$UNAME" = "Darwin" ]; then
    # macOS extensions are bundles, and undefined liblua symbols are resolved
    # against the host at load time.
    SHARED="-bundle -undefined dynamic_lookup"
fi

# shellcheck disable=SC2086
$CC $CFLAGS $SHARED $LUA_CFLAGS src/htmlsanitizer.c -o htmlsanitizer_native.so -ldl
echo "lua: built htmlsanitizer_native.so"

# A Lua 5.4 host, only when the distro ships liblua5.4 without the matching
# `lua5.4` binary (Debian 12 does exactly this). Twelve lines of C beats
# refusing to test.
if ! command -v lua5.4 >/dev/null 2>&1 && ! (command -v lua >/dev/null 2>&1 && lua -v 2>&1 | grep -q "Lua 5.4"); then
    # shellcheck disable=SC2086
    $CC ${CFLAGS} $LUA_CFLAGS host/lua54.c -o lua54 $LUA_LIBS -lm -ldl
    echo "lua: no lua5.4 binary on PATH — built the bundled ./lua54 host"
fi
