#!/bin/sh
# Build the canonical BEAM binding: the NIF plus its OTP application layout.
#
# Outputs, under erlang/_build/htmlsanitizer_nif/:
#   ebin/htmlsanitizer.beam
#   ebin/htmlsanitizer_nif.beam
#   ebin/htmlsanitizer_nif.app
#   priv/htmlsanitizer_nif.so      the NIF
#   priv/libhtmlsanitizer.so       the engine (staged; optional at build time)
#
# That directory IS the artifact elixir/ and gleam/ consume: they put its
# PARENT on ERL_LIBS and load the very same compiled module. No copied C.
#
# The NIF `dlopen`s the engine rather than linking it, so the engine .so does
# NOT need to exist to build this — only to run it. $1, when given, is the
# engine to stage into priv/.
#
# Exit codes: 0 built, 2 toolchain missing (the caller SKIPs), 1 real failure.
set -e

cd "$(dirname "$0")"

command -v erlc >/dev/null 2>&1 || { echo "erlang: erlc not on PATH" >&2; exit 2; }
command -v erl  >/dev/null 2>&1 || { echo "erlang: erl not on PATH" >&2; exit 2; }

CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "erlang: no C compiler" >&2; exit 2; }

# erl_nif.h lives in the erts include directory. Ask the runtime where its
# root is rather than guessing /usr/lib/erlang — that is wrong for kerl, asdf,
# Homebrew and any relocated install.
ERTS_INCLUDE="$(erl -noshell -eval \
  'io:format("~s", [filename:join([code:root_dir(), "erts-" ++ erlang:system_info(version), "include"])]), halt(0).' \
  2>/dev/null || true)"

if [ -z "$ERTS_INCLUDE" ] || [ ! -f "$ERTS_INCLUDE/erl_nif.h" ]; then
    # Debian/Ubuntu also drop a copy in /usr/include via erlang-dev.
    if [ -f /usr/include/erl_nif.h ]; then
        ERTS_INCLUDE=/usr/include
    else
        echo "erlang: erl_nif.h not found (install erlang-dev / erlang-devel)" >&2
        exit 2
    fi
fi

APP=_build/htmlsanitizer_nif
EBIN="$APP/ebin"
PRIV="$APP/priv"
mkdir -p "$EBIN" "$PRIV"

# 1. The NIF. No -lhtmlsanitizer: linking the engine would put a DT_NEEDED on
#    it and the BEAM would die inside the dynamic linker rather than report a
#    clean load error. -ldl for the dlopen the NIF does itself.
LDL=-ldl
case "$(uname -s)" in
    Darwin) LDL="" ;;   # dlopen is in libSystem on macOS
esac

# shellcheck disable=SC2086
"$CC" -O2 -fPIC -Wall -Wextra -shared \
    -I"$ERTS_INCLUDE" \
    c_src/htmlsanitizer_nif.c \
    -o "$PRIV/htmlsanitizer_nif.so" $LDL

# 2. The Erlang modules.
erlc -o "$EBIN" src/htmlsanitizer_nif.erl src/htmlsanitizer.erl

# 3. The .app file. app.src has no rebar substitutions in it, so a straight
#    copy is honest and keeps this build free of a rebar3 dependency.
cp -f src/htmlsanitizer_nif.app.src "$EBIN/htmlsanitizer_nif.app"

# 4. Stage the engine beside the NIF so priv/ is a self-contained app. The C
#    load callback looks in priv/ after $HTMLSANITIZER_LIB.
if [ -n "$1" ] && [ -f "$1" ]; then
    cp -f "$1" "$PRIV/libhtmlsanitizer.so"
fi

echo "erlang: built $APP"
