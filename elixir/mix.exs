defmodule HtmlSanitizer.MixProject do
  use Mix.Project

  @moduledoc """
  Build manifest for the Elixir surface over the canonical BEAM NIF.

  NOTE what is NOT here: no `make`, no `elixir_make`, no `c_src`. This project
  compiles nothing native. The NIF is built once by `erlang/.build.ae` and this
  project loads that already-compiled artifact — see `test/test_helper.exs`.

  That is deliberate. `elixir_make` is the usual way an Elixir package ships a
  NIF, but using it here would mean a SECOND copy of the C and a second `.so`,
  which is exactly what this monorepo's one-core rule forbids.
  """

  def project do
    [
      app: :html_sanitizer,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Clean HTML of XSS constructs — Elixir surface over the shared Aether sanitizer core",
      # No network access is needed to build or test this project; every
      # dependency list below is empty on purpose so `mix test` runs offline.
      docs: [main: "HtmlSanitizer"]
    ]
  end

  def application do
    # No `mod:` — there is no supervision tree. A sanitizer is a resource owned
    # by whoever created it, not a named process.
    #
    # `:htmlsanitizer_nif` is deliberately NOT listed in `extra_applications`:
    # Mix would then insist on finding it as a managed dependency, but it is an
    # OTP app built outside Mix and placed on the code path at runtime. The
    # modules load fine from the code path without an application start.
    [extra_applications: [:logger]]
  end

  defp deps do
    # Intentionally empty. The binding needs nothing but the NIF, and an empty
    # dep list is what keeps `mix test` runnable with no hex.pm access.
    []
  end
end
