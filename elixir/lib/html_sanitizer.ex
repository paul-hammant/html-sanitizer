defmodule HtmlSanitizer do
  @moduledoc """
  Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).

  This is a thin Elixir surface over the monorepo's **canonical BEAM NIF**,
  which lives in `erlang/` and is compiled exactly once. There is no C source
  in this directory and no second `.so` — every function here `defdelegate`s
  to `:htmlsanitizer_nif`, the very same compiled module the Erlang and Gleam
  bindings load. One engine, one NIF, three languages.

  The engine itself (`core/native/libhtmlsanitizer.so`) is pure Aether. No
  sanitizer logic lives anywhere in this file: everything marshals to an
  `aether_hs_embed_*` call across the C ABI in `core/embed.ae`.

      iex> {:ok, s} = HtmlSanitizer.new()
      iex> HtmlSanitizer.sanitize(s, "<div>Hello <script>evil()</script></div>")
      "<div>Hello </div>"

  ## Finding the NIF

  `mix` does **not** honour `ERL_LIBS`, unlike `erl`, `escript` and `gleam`.
  So the app built by `erlang/.build.ae` is put on the code path explicitly —
  see `test/test_helper.exs`, which reads `$HTMLSANITIZER_BEAM_APP` and calls
  `Code.append_path/1`. That is the one wrinkle of consuming an OTP app that
  Mix did not build.

  ## Callbacks

  This binding exposes **none** of the engine's hooks, so conformance checks
  10 and 11 are not implemented. A NIF cannot synchronously call back into the
  BEAM. See `README.md` for the full reasoning — the surface is absent rather
  than faked.
  """

  @typedoc "An opaque handle to a native sanitizer (an `enif_resource`)."
  @opaque t :: reference()

  @typedoc """
  One of the engine's six policy lists.

  These map onto the ABI's integer selectors, which are append-only and must
  never be renumbered.
  """
  @type list_name ::
          :tags
          | :attributes
          | :css_properties
          | :schemes
          | :classes
          | :uri_attributes

  # ---- lifecycle ----

  @doc """
  Create a sanitizer with the engine's secure defaults populated.

  The handle is an `enif_resource`: the BEAM's GC releases the native handle
  when the last reference goes, so a dropped sanitizer leaks nothing.
  `close/1` makes that deterministic.
  """
  @spec new() :: {:ok, t()} | {:error, term()}
  defdelegate new(), to: :htmlsanitizer_nif

  @doc """
  Release the native handle. Idempotent.

  After this, `closed?/1` is `true` and `sanitize_r/3` returns
  `{:error, :closed}` rather than dereferencing a freed pointer.
  """
  @spec close(t()) :: :ok
  defdelegate close(sanitizer), to: :htmlsanitizer_nif

  @doc "Whether `close/1` has been called."
  @spec closed?(t()) :: boolean()
  defdelegate closed?(sanitizer), to: :htmlsanitizer_nif, as: :is_closed

  @doc """
  Run `fun` with a fresh sanitizer, closing it afterwards even on a raise.

  The Elixir-idiomatic bracket. Prefer it over hand-written new/close pairs.

      HtmlSanitizer.with_sanitizer(fn s ->
        HtmlSanitizer.sanitize(s, html)
      end)
  """
  @spec with_sanitizer((t() -> result)) :: result when result: var
  def with_sanitizer(fun) when is_function(fun, 1) do
    {:ok, s} = new()

    try do
      fun.(s)
    after
      close(s)
    end
  end

  # ---- sanitizing ----

  @doc """
  Clean an HTML fragment.

  `base_url` resolves relative URLs; pass `""` (the default) for no
  resolution. Input is `iodata`, so an unflattened iolist is fine.

  Returns `""` on a closed sanitizer — use `sanitize_r/3` when you need that
  distinguished from a legitimately empty result.

      iex> HtmlSanitizer.with_sanitizer(fn s ->
      ...>   HtmlSanitizer.sanitize(s, ~s(<img src="logo.png">), "https://example.com")
      ...> end)
      ~s(<img src="https://example.com/logo.png">)
  """
  @spec sanitize(t(), iodata(), iodata()) :: binary()
  def sanitize(sanitizer, html, base_url \\ ""), do: unwrap(sanitize_r(sanitizer, html, base_url))

  @doc "Like `sanitize/3` but reports `{:error, :closed}` instead of `\"\"`."
  @spec sanitize_r(t(), iodata(), iodata()) :: {:ok, binary()} | {:error, :closed}
  defdelegate sanitize_r(sanitizer, html, base_url), to: :htmlsanitizer_nif, as: :sanitize

  @doc "Clean a whole HTML document."
  @spec sanitize_document(t(), iodata(), iodata()) :: binary()
  def sanitize_document(sanitizer, html, base_url \\ ""),
    do: unwrap(sanitize_document_r(sanitizer, html, base_url))

  @doc "Like `sanitize_document/3` but reports `{:error, :closed}`."
  @spec sanitize_document_r(t(), iodata(), iodata()) :: {:ok, binary()} | {:error, :closed}
  defdelegate sanitize_document_r(sanitizer, html, base_url),
    to: :htmlsanitizer_nif,
    as: :sanitize_document

  defp unwrap({:ok, bin}), do: bin
  defp unwrap({:error, _}), do: ""

  # ---- flags ----

  @doc "Whether children of a removed element are kept."
  @spec keep_child_nodes(t()) :: boolean()
  defdelegate keep_child_nodes(sanitizer), to: :htmlsanitizer_nif, as: :get_keep_child_nodes

  @doc "Keep the children of a removed element instead of dropping the subtree."
  @spec set_keep_child_nodes(t(), boolean()) :: :ok
  defdelegate set_keep_child_nodes(sanitizer, on), to: :htmlsanitizer_nif

  @doc "Whether `data-*` attributes pass without being listed."
  @spec allow_data_attributes(t()) :: boolean()
  defdelegate allow_data_attributes(sanitizer),
    to: :htmlsanitizer_nif,
    as: :get_allow_data_attributes

  @doc "Let `data-*` attributes through without listing each one."
  @spec set_allow_data_attributes(t(), boolean()) :: :ok
  defdelegate set_allow_data_attributes(sanitizer, on), to: :htmlsanitizer_nif

  # ---- policy lists ----
  #
  # The ABI takes an integer selector; Elixir callers name the list with an
  # atom and never see the number. These constants are ABI — append only,
  # never renumber (core/embed.ae).

  @which %{
    tags: 0,
    attributes: 1,
    css_properties: 2,
    schemes: 3,
    classes: 4,
    uri_attributes: 5
  }

  defp which(name) when is_map_key(@which, name), do: Map.fetch!(@which, name)

  @doc """
  Add one item, or a list of items, to a policy list.

      HtmlSanitizer.allow(s, :tags, "my-widget")
      HtmlSanitizer.allow(s, :tags, ["one", "two"])
  """
  @spec allow(t(), list_name(), iodata() | [iodata()]) :: boolean()
  def allow(sanitizer, list, items) when is_list(items),
    do: Enum.all?(items, &allow(sanitizer, list, &1))

  def allow(sanitizer, list, item),
    do: :htmlsanitizer_nif.allow(sanitizer, which(list), item)

  @doc "Remove an item from a policy list (the \"deny\" direction)."
  @spec disallow(t(), list_name(), iodata() | [iodata()]) :: boolean()
  def disallow(sanitizer, list, items) when is_list(items),
    do: Enum.all?(items, &disallow(sanitizer, list, &1))

  def disallow(sanitizer, list, item),
    do: :htmlsanitizer_nif.disallow(sanitizer, which(list), item)

  @doc "Whether an item is currently in a policy list."
  @spec allowed?(t(), list_name(), iodata()) :: boolean()
  def allowed?(sanitizer, list, item),
    do: :htmlsanitizer_nif.is_allowed(sanitizer, which(list), item)

  @doc """
  Empty a policy list.

  The "start from nothing" move for a caller who wants a strict allow-list
  rather than the engine's permissive defaults.
  """
  @spec clear(t(), list_name()) :: boolean()
  def clear(sanitizer, list), do: :htmlsanitizer_nif.clear(sanitizer, which(list))

  @doc "How many entries a policy list has."
  @spec count(t(), list_name()) :: non_neg_integer()
  def count(sanitizer, list), do: :htmlsanitizer_nif.count(sanitizer, which(list))

  @doc """
  Enumerate a policy list.

  Order is unspecified but stable between mutations; use `sorted_items/2` when
  determinism matters.
  """
  @spec items(t(), list_name()) :: [binary()]
  def items(sanitizer, list), do: :htmlsanitizer_nif.items(sanitizer, which(list))

  @doc "`items/2`, sorted."
  @spec sorted_items(t(), list_name()) :: [binary()]
  def sorted_items(sanitizer, list), do: Enum.sort(items(sanitizer, list))

  # ---- introspection ----

  @doc "The engine's ABI revision."
  @spec abi_version() :: non_neg_integer()
  defdelegate abi_version(), to: :htmlsanitizer_nif
end
