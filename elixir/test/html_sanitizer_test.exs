defmodule HtmlSanitizerTest do
  @moduledoc """
  The binding conformance suite (docs/conformance.md).

  Proves the Elixir surface marshals every value shape across the FFI. It is
  NOT a sanitizer test suite — the behavioural cases live in the sanitizer core's own
  tests and run once, in Aether.

  Checks 10 (`on_removing_tag` cancels) and 11 (`on_filter_url` rewrites) are
  ABSENT ON PURPOSE: a NIF cannot synchronously call back into the BEAM, so
  the shared NIF exposes no hooks at all. See README.md. The other ten are
  covered in full.
  """

  # async: false — each test creates its own sanitizer, but they all share one
  # NIF and one loaded sanitizer core, and a handle is not safe for concurrent use.
  use ExUnit.Case, async: false

  doctest HtmlSanitizer

  setup do
    {:ok, s} = HtmlSanitizer.new()
    on_exit(fn -> HtmlSanitizer.close(s) end)
    {:ok, s: s}
  end

  # ---- the 12 checks (10 and 11 deliberately absent) ----

  test "01 script removed", %{s: s} do
    assert HtmlSanitizer.sanitize(s, "<div>Hello <script>alert(1)</script> world!</div>") ==
             "<div>Hello  world!</div>"
  end

  test "02 onclick removed", %{s: s} do
    assert HtmlSanitizer.sanitize(s, ~s|<div onclick="alert(1)">Hello</div>|) ==
             "<div>Hello</div>"
  end

  test "03 empty string", %{s: s} do
    assert HtmlSanitizer.sanitize(s, "") == ""
  end

  test "04 utf-8 round trip", %{s: s} do
    # Build the multibyte content by codepoint so the source stays pure
    # ASCII: 0xE9 is e-acute, 0x2615 is the hot-beverage emoji. Raw multibyte
    # literals trip Elixir 1.16's parser once a line carries several of them.
    html = "<div>caf" <> <<0xE9::utf8, ?\s, 0x2615::utf8>> <> "</div>"
    assert HtmlSanitizer.sanitize(s, html) == html
  end

  test "05 allow custom tag", %{s: s} do
    assert HtmlSanitizer.sanitize(s, "<my-widget>x</my-widget>") == ""
    assert HtmlSanitizer.allow(s, :tags, "my-widget")

    assert HtmlSanitizer.sanitize(s, "<my-widget>x</my-widget>") ==
             "<my-widget>x</my-widget>"
  end

  test "06 disallow tag", %{s: s} do
    assert HtmlSanitizer.sanitize(s, "<div>x</div>") == "<div>x</div>"
    assert HtmlSanitizer.disallow(s, :tags, "div")
    assert HtmlSanitizer.sanitize(s, "<div>x</div>") == ""
  end

  test "07 membership and count", %{s: s} do
    assert HtmlSanitizer.allowed?(s, :schemes, "http")
    refute HtmlSanitizer.allowed?(s, :schemes, "gopher")
    assert HtmlSanitizer.count(s, :schemes) == 2
  end

  test "08 enumeration", %{s: s} do
    assert HtmlSanitizer.sorted_items(s, :schemes) == ["http", "https"]
  end

  test "09 keep_child_nodes", %{s: s} do
    html = "<div><nope>Hello <span>world</span></nope></div>"
    assert HtmlSanitizer.sanitize(s, html) == "<div></div>"
    assert :ok == HtmlSanitizer.set_keep_child_nodes(s, true)
    assert HtmlSanitizer.keep_child_nodes(s)
    assert HtmlSanitizer.sanitize(s, html) == "<div>Hello <span>world</span></div>"
  end

  # Checks 10 and 11 are not implementable on the BEAM — see README.md. This
  # test documents the gap rather than leaving a silent hole: if hooks are ever
  # added to the NIF, whoever adds them will find this and delete it.
  test "10 and 11 callbacks are not supported on the BEAM" do
    refute function_exported?(HtmlSanitizer, :on_removing_tag, 2)
    refute function_exported?(HtmlSanitizer, :on_filter_url, 2)
    refute function_exported?(:htmlsanitizer_nif, :on_removing_tag, 3)
  end

  test "12 handles are independent" do
    {:ok, a} = HtmlSanitizer.new()
    {:ok, b} = HtmlSanitizer.new()

    try do
      assert HtmlSanitizer.allow(a, :tags, "only-in-a")
      assert HtmlSanitizer.allowed?(a, :tags, "only-in-a")
      refute HtmlSanitizer.allowed?(b, :tags, "only-in-a")
    after
      HtmlSanitizer.close(a)
      HtmlSanitizer.close(b)
    end
  end

  # ---- extras: the marshalling corners the 12 do not reach ----

  test "abi version" do
    assert HtmlSanitizer.abi_version() >= 1
  end

  test "sanitize_document", %{s: s} do
    assert HtmlSanitizer.sanitize_document(s, "<div>doc<script>x</script></div>") ==
             "<html><head></head><body><div>doc</div></body></html>"
  end

  test "base url resolution", %{s: s} do
    assert HtmlSanitizer.sanitize(s, ~s|<img src="logo.png">|, "https://example.com") ==
             ~s|<img src="https://example.com/logo.png">|
  end

  # The NIF takes iodata, so a caller assembling HTML from a list should not
  # have to flatten it first.
  test "iodata input", %{s: s} do
    assert HtmlSanitizer.sanitize(s, ["<div>", "a", [?b], "</div>"]) == "<div>ab</div>"
  end

  test "allow_data_attributes", %{s: s} do
    assert HtmlSanitizer.sanitize(s, ~s|<div data-x="1"></div>|) == "<div></div>"
    assert :ok == HtmlSanitizer.set_allow_data_attributes(s, true)
    assert HtmlSanitizer.allow_data_attributes(s)
    assert HtmlSanitizer.sanitize(s, ~s|<div data-x="1"></div>|) == ~s|<div data-x="1"></div>|
  end

  test "clear empties a list", %{s: s} do
    assert HtmlSanitizer.clear(s, :schemes)
    assert HtmlSanitizer.count(s, :schemes) == 0
    assert HtmlSanitizer.items(s, :schemes) == []
  end

  test "bulk allow and disallow", %{s: s} do
    assert HtmlSanitizer.allow(s, :tags, ["one-tag", "two-tag"])
    assert HtmlSanitizer.allowed?(s, :tags, "one-tag")
    assert HtmlSanitizer.allowed?(s, :tags, "two-tag")
    assert HtmlSanitizer.disallow(s, :tags, ["one-tag", "two-tag"])
    refute HtmlSanitizer.allowed?(s, :tags, "one-tag")
  end

  # A closed sanitizer must report itself closed rather than dereference a
  # freed pointer — the resource is still a live BEAM term after close/1.
  test "closed sanitizer rejects use" do
    {:ok, s} = HtmlSanitizer.new()
    assert :ok == HtmlSanitizer.close(s)
    assert HtmlSanitizer.closed?(s)
    assert {:error, :closed} == HtmlSanitizer.sanitize_r(s, "<div>x</div>", "")
    assert HtmlSanitizer.sanitize(s, "<div>x</div>") == ""
    # close/1 is idempotent
    assert :ok == HtmlSanitizer.close(s)
  end

  test "with_sanitizer closes even when the body raises" do
    assert_raise RuntimeError, fn ->
      HtmlSanitizer.with_sanitizer(fn _s -> raise "boom" end)
    end

    # And returns the body's value on the happy path.
    assert HtmlSanitizer.with_sanitizer(fn s ->
             HtmlSanitizer.sanitize(s, "<div>x</div>")
           end) == "<div>x</div>"
  end

  # A sanitizer nobody closed must still release its native handle when the GC
  # collects the resource. We cannot observe the free directly, but we can
  # prove the destructor path runs without crashing the VM under a forced GC.
  test "dropped sanitizers are collected" do
    Enum.each(1..50, fn _ ->
      {:ok, s} = HtmlSanitizer.new()
      _ = HtmlSanitizer.sanitize(s, "<div>x</div>")
      # deliberately no close/1
    end)

    :erlang.garbage_collect()
    assert true
  end
end
