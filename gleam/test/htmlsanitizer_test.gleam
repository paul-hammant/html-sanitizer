//// The binding conformance suite (docs/conformance.md).
////
//// Proves the Gleam surface marshals every value shape across the FFI. It is
//// NOT a sanitizer test suite — the behavioural cases live in the engine's own
//// tests and run once, in Aether.
////
//// Checks 10 (`on_removing_tag` cancels) and 11 (`on_filter_url` rewrites) are
//// ABSENT ON PURPOSE: a NIF cannot synchronously call back into the BEAM, so
//// the shared NIF exposes no hooks at all. See README.md. The other ten are
//// covered in full.

import gleam/list
import gleeunit
import gleeunit/should
import htmlsanitizer.{
  Attributes, Classes, CssProperties, Schemes, Tags, UriAttributes,
}

pub fn main() {
  gleeunit.main()
}

/// Run a test body against a fresh sanitizer and close it afterwards, so no
/// test can leak policy state into the next.
fn with_sanitizer(body: fn(htmlsanitizer.Sanitizer) -> a) -> a {
  let assert Ok(s) = htmlsanitizer.new()
  let out = body(s)
  htmlsanitizer.close(s)
  out
}

// ---- the 12 checks (10 and 11 deliberately absent) ----

pub fn t01_script_removed_test() {
  use s <- with_sanitizer()
  htmlsanitizer.sanitize(s, "<div>Hello <script>alert(1)</script> world!</div>")
  |> should.equal("<div>Hello  world!</div>")
}

pub fn t02_onclick_removed_test() {
  use s <- with_sanitizer()
  htmlsanitizer.sanitize(s, "<div onclick=\"alert(1)\">Hello</div>")
  |> should.equal("<div>Hello</div>")
}

pub fn t03_empty_string_test() {
  use s <- with_sanitizer()
  htmlsanitizer.sanitize(s, "")
  |> should.equal("")
}

pub fn t04_utf8_round_trip_test() {
  use s <- with_sanitizer()
  htmlsanitizer.sanitize(s, "<div>café ☕</div>")
  |> should.equal("<div>café ☕</div>")
}

pub fn t05_allow_custom_tag_test() {
  use s <- with_sanitizer()
  htmlsanitizer.sanitize(s, "<my-widget>x</my-widget>")
  |> should.equal("")

  htmlsanitizer.allow(s, Tags, "my-widget")
  |> should.be_true

  htmlsanitizer.sanitize(s, "<my-widget>x</my-widget>")
  |> should.equal("<my-widget>x</my-widget>")
}

pub fn t06_disallow_tag_test() {
  use s <- with_sanitizer()
  htmlsanitizer.sanitize(s, "<div>x</div>")
  |> should.equal("<div>x</div>")

  htmlsanitizer.disallow(s, Tags, "div")
  |> should.be_true

  htmlsanitizer.sanitize(s, "<div>x</div>")
  |> should.equal("")
}

pub fn t07_membership_and_count_test() {
  use s <- with_sanitizer()
  htmlsanitizer.is_allowed(s, Schemes, "http")
  |> should.be_true

  htmlsanitizer.is_allowed(s, Schemes, "gopher")
  |> should.be_false

  htmlsanitizer.count(s, Schemes)
  |> should.equal(2)
}

pub fn t08_enumeration_test() {
  use s <- with_sanitizer()
  htmlsanitizer.sorted_items(s, Schemes)
  |> should.equal(["http", "https"])
}

pub fn t09_keep_child_nodes_test() {
  use s <- with_sanitizer()
  let html = "<div><nope>Hello <span>world</span></nope></div>"

  htmlsanitizer.sanitize(s, html)
  |> should.equal("<div></div>")

  htmlsanitizer.set_keep_child_nodes(s, True)

  htmlsanitizer.keep_child_nodes(s)
  |> should.be_true

  htmlsanitizer.sanitize(s, html)
  |> should.equal("<div>Hello <span>world</span></div>")
}

// Checks 10 and 11 are not implementable on the BEAM — see README.md. There is
// no hook surface to call, so there is nothing to assert here beyond the fact
// that the module compiles without one; the Erlang and Elixir suites assert
// the absence directly via function_exported?.

pub fn t12_handles_are_independent_test() {
  let assert Ok(a) = htmlsanitizer.new()
  let assert Ok(b) = htmlsanitizer.new()

  htmlsanitizer.allow(a, Tags, "only-in-a")
  |> should.be_true

  htmlsanitizer.is_allowed(a, Tags, "only-in-a")
  |> should.be_true

  htmlsanitizer.is_allowed(b, Tags, "only-in-a")
  |> should.be_false

  htmlsanitizer.close(a)
  htmlsanitizer.close(b)
}

// ---- extras: the marshalling corners the 12 do not reach ----

pub fn abi_version_test() {
  { htmlsanitizer.abi_version() >= 1 }
  |> should.be_true
}

pub fn sanitize_document_test() {
  use s <- with_sanitizer()
  htmlsanitizer.sanitize_document(s, "<div>doc<script>x</script></div>")
  |> should.equal("<html><head></head><body><div>doc</div></body></html>")
}

pub fn base_url_resolution_test() {
  use s <- with_sanitizer()
  htmlsanitizer.sanitize_with_base(
    s,
    "<img src=\"logo.png\">",
    "https://example.com",
  )
  |> should.equal("<img src=\"https://example.com/logo.png\">")
}

pub fn allow_data_attributes_test() {
  use s <- with_sanitizer()
  htmlsanitizer.sanitize(s, "<div data-x=\"1\"></div>")
  |> should.equal("<div></div>")

  htmlsanitizer.set_allow_data_attributes(s, True)

  htmlsanitizer.allow_data_attributes(s)
  |> should.be_true

  htmlsanitizer.sanitize(s, "<div data-x=\"1\"></div>")
  |> should.equal("<div data-x=\"1\"></div>")
}

pub fn clear_empties_a_list_test() {
  use s <- with_sanitizer()
  htmlsanitizer.clear(s, Schemes)
  |> should.be_true

  htmlsanitizer.count(s, Schemes)
  |> should.equal(0)

  htmlsanitizer.items(s, Schemes)
  |> should.equal([])
}

pub fn allow_all_test() {
  use s <- with_sanitizer()
  htmlsanitizer.allow_all(s, Tags, ["one-tag", "two-tag"])
  |> should.be_true

  htmlsanitizer.is_allowed(s, Tags, "one-tag")
  |> should.be_true

  htmlsanitizer.is_allowed(s, Tags, "two-tag")
  |> should.be_true
}

/// Every policy list must be reachable — this catches a mistyped selector,
/// which would otherwise silently address the wrong list.
pub fn every_policy_list_is_addressable_test() {
  use s <- with_sanitizer()
  [Tags, Attributes, CssProperties, Schemes, Classes, UriAttributes]
  |> list.each(fn(policy) {
    htmlsanitizer.allow(s, policy, "probe-item")
    |> should.be_true

    htmlsanitizer.is_allowed(s, policy, "probe-item")
    |> should.be_true
  })
}

/// A closed sanitizer must report itself closed rather than dereference a
/// freed pointer — the resource is still a live BEAM term after close.
pub fn closed_sanitizer_rejects_use_test() {
  let assert Ok(s) = htmlsanitizer.new()
  htmlsanitizer.close(s)

  htmlsanitizer.is_closed(s)
  |> should.be_true

  htmlsanitizer.try_sanitize(s, "<div>x</div>", "")
  |> should.equal(Error(htmlsanitizer.Closed))

  // The lenient wrapper degrades to "" rather than crashing.
  htmlsanitizer.sanitize(s, "<div>x</div>")
  |> should.equal("")

  // close is idempotent
  htmlsanitizer.close(s)
}
