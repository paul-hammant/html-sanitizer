//// Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).
////
//// This is a thin Gleam surface over the monorepo's **canonical BEAM NIF**,
//// which lives in `erlang/` and is compiled exactly once. There is no C source
//// in this directory and no second `.so` — every function here is an
//// `@external(erlang, "htmlsanitizer_nif", ...)` binding onto the very same
//// compiled module the Erlang and Elixir bindings load. One sanitizer core, one NIF,
//// three languages.
////
//// The sanitizer core itself (`core/native/libhtmlsanitizer.so`) is pure Aether. No
//// sanitizer logic lives in this file: everything marshals to an
//// `aether_hs_embed_*` call across the C ABI in `core/embed.ae`.
////
//// ```gleam
//// let assert Ok(s) = htmlsanitizer.new()
//// htmlsanitizer.sanitize(s, "<div>Hello <script>evil()</script></div>")
//// // -> "<div>Hello </div>"
//// htmlsanitizer.close(s)
//// ```
////
//// ## Finding the NIF
////
//// `gleam` honours `$ERL_LIBS`, so pointing it at the directory containing the
//// app built by `erlang/.build.ae` is all that is needed — see
//// `gleam/.tests.ae`. (Mix, by contrast, does not; that is why the Elixir
//// binding has to `Code.append_path` instead.)
////
//// ## Callbacks
////
//// This binding exposes **none** of the sanitizer core's hooks, so conformance checks
//// 10 and 11 are not implemented. A NIF cannot synchronously call back into
//// the BEAM. See `README.md` — the surface is absent rather than faked.
////
//// ## Gleam is target-specific here
////
//// This module is **Erlang-target only**. It cannot compile to JavaScript,
//// because the whole binding is a NIF. That is not a limitation worth working
//// around: the monorepo already has a JavaScript binding that talks to the
//// same sanitizer core over koffi.

import gleam/list
import gleam/string

/// An opaque handle to a native sanitizer.
///
/// It is an `enif_resource`: the BEAM's GC releases the native handle when the
/// last reference goes, so a dropped sanitizer leaks nothing. `close` makes
/// that deterministic.
pub type Sanitizer

/// Why a sanitizer call failed.
pub type Error {
  /// The sanitizer has already been closed.
  Closed
  /// The sanitizer core refused to allocate a sanitizer.
  AllocFailed
}

/// One of the sanitizer core's six policy lists.
///
/// These map onto the ABI's integer selectors, which are append-only and must
/// never be renumbered.
pub type PolicyList {
  Tags
  Attributes
  CssProperties
  Schemes
  Classes
  UriAttributes
}

/// The ABI selector for a policy list (core/embed.ae — append only).
fn which(policy: PolicyList) -> Int {
  case policy {
    Tags -> 0
    Attributes -> 1
    CssProperties -> 2
    Schemes -> 3
    Classes -> 4
    UriAttributes -> 5
  }
}

// ---- lifecycle ----

/// Create a sanitizer with the sanitizer core's secure defaults populated.
@external(erlang, "htmlsanitizer_nif", "new")
pub fn new() -> Result(Sanitizer, Error)

/// Release the native handle. Idempotent.
///
/// After this, `is_closed` is `True` and `try_sanitize` returns `Error(Closed)`
/// rather than dereferencing a freed pointer.
@external(erlang, "htmlsanitizer_nif", "close")
pub fn close(sanitizer: Sanitizer) -> Nil

/// Whether `close` has been called.
@external(erlang, "htmlsanitizer_nif", "is_closed")
pub fn is_closed(sanitizer: Sanitizer) -> Bool

// ---- sanitizing ----
//
// The NIF returns {ok, Binary} | {error, closed}. Gleam models that as a
// Result directly — the tuple shapes line up, so no conversion layer is
// needed between the two.

/// Clean an HTML fragment, reporting a closed sanitizer as an error.
///
/// `base_url` resolves relative URLs; pass `""` for no resolution.
@external(erlang, "htmlsanitizer_nif", "sanitize")
pub fn try_sanitize(
  sanitizer: Sanitizer,
  html: String,
  base_url: String,
) -> Result(String, Error)

/// Clean a whole HTML document, reporting a closed sanitizer as an error.
@external(erlang, "htmlsanitizer_nif", "sanitize_document")
pub fn try_sanitize_document(
  sanitizer: Sanitizer,
  html: String,
  base_url: String,
) -> Result(String, Error)

/// Clean an HTML fragment with no base URL.
///
/// Returns `""` on a closed sanitizer; use `try_sanitize` when you need that
/// distinguished from a legitimately empty result.
pub fn sanitize(sanitizer: Sanitizer, html: String) -> String {
  sanitize_with_base(sanitizer, html, "")
}

/// Clean an HTML fragment, resolving relative URLs against `base_url`.
///
/// ```gleam
/// htmlsanitizer.sanitize_with_base(s, "<img src=\"logo.png\">", "https://example.com")
/// // -> "<img src=\"https://example.com/logo.png\">"
/// ```
pub fn sanitize_with_base(
  sanitizer: Sanitizer,
  html: String,
  base_url: String,
) -> String {
  case try_sanitize(sanitizer, html, base_url) {
    Ok(out) -> out
    Error(_) -> ""
  }
}

/// Clean a whole HTML document with no base URL.
pub fn sanitize_document(sanitizer: Sanitizer, html: String) -> String {
  case try_sanitize_document(sanitizer, html, "") {
    Ok(out) -> out
    Error(_) -> ""
  }
}

// ---- flags ----

/// Whether children of a removed element are kept.
@external(erlang, "htmlsanitizer_nif", "get_keep_child_nodes")
pub fn keep_child_nodes(sanitizer: Sanitizer) -> Bool

/// Keep the children of a removed element instead of dropping the subtree.
@external(erlang, "htmlsanitizer_nif", "set_keep_child_nodes")
pub fn set_keep_child_nodes(sanitizer: Sanitizer, on: Bool) -> Nil

/// Whether `data-*` attributes pass without being listed.
@external(erlang, "htmlsanitizer_nif", "get_allow_data_attributes")
pub fn allow_data_attributes(sanitizer: Sanitizer) -> Bool

/// Let `data-*` attributes through without listing each one.
@external(erlang, "htmlsanitizer_nif", "set_allow_data_attributes")
pub fn set_allow_data_attributes(sanitizer: Sanitizer, on: Bool) -> Nil

// ---- policy lists ----
//
// The NIF takes the integer selector; these wrappers take the PolicyList type
// so a Gleam caller never writes a bare number and cannot pass an out-of-range
// one. The `_ffi` bindings below are private for exactly that reason.

@external(erlang, "htmlsanitizer_nif", "allow")
fn allow_ffi(sanitizer: Sanitizer, which: Int, item: String) -> Bool

@external(erlang, "htmlsanitizer_nif", "disallow")
fn disallow_ffi(sanitizer: Sanitizer, which: Int, item: String) -> Bool

@external(erlang, "htmlsanitizer_nif", "is_allowed")
fn is_allowed_ffi(sanitizer: Sanitizer, which: Int, item: String) -> Bool

@external(erlang, "htmlsanitizer_nif", "clear")
fn clear_ffi(sanitizer: Sanitizer, which: Int) -> Bool

@external(erlang, "htmlsanitizer_nif", "count")
fn count_ffi(sanitizer: Sanitizer, which: Int) -> Int

@external(erlang, "htmlsanitizer_nif", "items")
fn items_ffi(sanitizer: Sanitizer, which: Int) -> List(String)

/// Add an item to a policy list.
pub fn allow(sanitizer: Sanitizer, policy: PolicyList, item: String) -> Bool {
  allow_ffi(sanitizer, which(policy), item)
}

/// Add several items to a policy list.
pub fn allow_all(
  sanitizer: Sanitizer,
  policy: PolicyList,
  items: List(String),
) -> Bool {
  list.all(items, fn(item) { allow(sanitizer, policy, item) })
}

/// Remove an item from a policy list (the "deny" direction).
pub fn disallow(sanitizer: Sanitizer, policy: PolicyList, item: String) -> Bool {
  disallow_ffi(sanitizer, which(policy), item)
}

/// Whether an item is currently in a policy list.
pub fn is_allowed(sanitizer: Sanitizer, policy: PolicyList, item: String) -> Bool {
  is_allowed_ffi(sanitizer, which(policy), item)
}

/// Empty a policy list.
///
/// The "start from nothing" move for a caller who wants a strict allow-list
/// rather than the sanitizer core's permissive defaults.
pub fn clear(sanitizer: Sanitizer, policy: PolicyList) -> Bool {
  clear_ffi(sanitizer, which(policy))
}

/// How many entries a policy list has.
pub fn count(sanitizer: Sanitizer, policy: PolicyList) -> Int {
  count_ffi(sanitizer, which(policy))
}

/// Enumerate a policy list.
///
/// Order is unspecified but stable between mutations; use `sorted_items` when
/// determinism matters.
pub fn items(sanitizer: Sanitizer, policy: PolicyList) -> List(String) {
  items_ffi(sanitizer, which(policy))
}

/// `items`, sorted.
pub fn sorted_items(sanitizer: Sanitizer, policy: PolicyList) -> List(String) {
  list.sort(items(sanitizer, policy), string.compare)
}

// ---- introspection ----

/// The sanitizer core's ABI revision.
@external(erlang, "htmlsanitizer_nif", "abi_version")
pub fn abi_version() -> Int
