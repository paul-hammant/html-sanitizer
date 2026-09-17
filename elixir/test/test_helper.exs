# Put the canonical BEAM NIF on the code path before any test runs.
#
# THE WRINKLE: `erl`, `escript` and `gleam` all honour $ERL_LIBS, so the Erlang
# and Gleam bindings find the app built by erlang/.build.ae for free. **Mix does
# not.** It builds its own code path from `deps/` and `_build/`, and an OTP app
# that Mix did not build is simply invisible to it.
#
# So elixir/.tests.ae exports $HTMLSANITIZER_BEAM_APP (the `beam_app` artifact
# from the erlang/.build.ae node) and we append its ebin/ here. This is the
# whole reason there is no C source in elixir/: we load the SAME compiled
# htmlsanitizer_nif.beam and the SAME priv/htmlsanitizer_nif.so that the Erlang
# binding uses, rather than building a second copy.

case System.get_env("HTMLSANITIZER_BEAM_APP") do
  nil ->
    # Fall back to the in-tree location so `mix test` works by hand after a
    # plain `aeb erlang/.build.ae`.
    default = Path.expand("../../erlang/_build/htmlsanitizer_nif", __DIR__)

    if File.dir?(Path.join(default, "ebin")) do
      Code.append_path(Path.join(default, "ebin"))
    else
      IO.puts(:stderr, """
      html_sanitizer: cannot find the NIF application.

      Build it first:
          aeb erlang/.build.ae
      or point $HTMLSANITIZER_BEAM_APP at the built app directory
      (the one containing ebin/ and priv/).
      """)

      System.halt(1)
    end

  app ->
    ebin = Path.join(app, "ebin")

    unless File.dir?(ebin) do
      IO.puts(:stderr, "html_sanitizer: $HTMLSANITIZER_BEAM_APP=#{app} has no ebin/")
      System.halt(1)
    end

    Code.append_path(ebin)
end

# Load the NIF module now rather than at first use, so a load failure is
# reported here — with the sanitizer core path in the message — instead of surfacing as
# a confusing :nif_error deep inside a test.
case Code.ensure_loaded(:htmlsanitizer_nif) do
  {:module, _} ->
    :ok

  {:error, reason} ->
    IO.puts(:stderr, """
    html_sanitizer: could not load :htmlsanitizer_nif (#{inspect(reason)}).

    The NIF dlopens the sanitizer core; set $HTMLSANITIZER_LIB to the absolute path of
    libhtmlsanitizer.so if it is not beside the NIF in priv/.
    """)

    System.halt(1)
end

ExUnit.start()
