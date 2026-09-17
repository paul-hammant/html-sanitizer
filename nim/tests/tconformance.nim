## The 12-check binding conformance suite (docs/conformance.md), in Nim.
##
## Proves this binding marshals every value shape across the FFI. It is NOT a
## sanitizer test suite — the behavioural cases live in the sanitizer core's own tests
## and run once, in Aether (`core_tests/`).
##
## This binding skips nothing: Nim can hand C a real function pointer, so
## checks 10 and 11 — the callback trampoline and the string-returning
## `onFilterUrl` — are implemented and passing here, not waived.
##
## Run it directly (no nimble needed):
##
##     nim c -r tests/tconformance.nim
##
## The sanitizer core must be linkable: `nim/.tests.ae` stages it into `nim/native/`,
## and an in-tree checkout also has `core/native/libhtmlsanitizer.so`. Both
## directories are baked into the binary as rpath by `src/htmlsanitizer.nim`.

import std/[strutils, unittest]
import ../src/htmlsanitizer

suite "conformance":

  # ---- 1..9: values across the FFI ----

  test "01 script removed":
    withSanitizer s:
      check s.sanitize("<div>Hello <script>alert(1)</script> world!</div>") ==
        "<div>Hello  world!</div>"

  test "02 onclick removed":
    withSanitizer s:
      check s.sanitize("""<div onclick="alert(1)">Hello</div>""") == "<div>Hello</div>"

  test "03 empty string":
    # The classic NULL-vs-"" bug: an empty result must be an empty string, not
    # a null pointer that decodes to garbage or crashes.
    withSanitizer s:
      check s.sanitize("") == ""

  test "04 utf8 round trip":
    # Nim strings are bytes, so this only passes if nothing re-encoded them on
    # the way through the ABI.
    withSanitizer s:
      check s.sanitize("<div>café ☕</div>") == "<div>café ☕</div>"

  test "05 allow custom tag":
    withSanitizer s:
      check s.sanitize("<my-widget>x</my-widget>") == ""
      s.allowedTags.add "my-widget"
      check s.sanitize("<my-widget>x</my-widget>") == "<my-widget>x</my-widget>"

  test "06 disallow tag":
    withSanitizer s:
      check s.sanitize("<div>x</div>") == "<div>x</div>"
      s.allowedTags.excl "div"
      check s.sanitize("<div>x</div>") == ""

  test "07 membership and count":
    withSanitizer s:
      check "http" in s.allowedSchemes
      check "gopher" notin s.allowedSchemes
      check s.allowedSchemes.len == 2

  test "08 enumeration":
    # The item_at / MapKeys read path.
    withSanitizer s:
      check s.allowedSchemes.sorted() == @["http", "https"]

  test "09 keep child nodes":
    withSanitizer s:
      check s.sanitize("<div><nope>Hello <span>world</span></nope></div>") ==
        "<div></div>"
      s.keepChildNodes = true
      check s.keepChildNodes == true
      check s.sanitize("<div><nope>Hello <span>world</span></nope></div>") ==
        "<div>Hello <span>world</span></div>"

  # ---- 10 and 11: the callback shapes. Implemented, not skipped. ----

  test "10 on_removing_tag cancels":
    withSanitizer s:
      var seen: seq[(string, Reason)] = @[]
      # A closure capturing a local: it stays alive because the handler is
      # stored on the GC_ref'd Sanitizer.
      s.onRemovingTag(proc (node: Node, reason: Reason): bool =
        let n = node.name
        seen.add (n, reason)
        n == "keep-me")            # true CANCELS the removal
      check s.sanitize("<div><keep-me>a</keep-me><drop-me>b</drop-me></div>") ==
        "<div><keep-me>a</keep-me></div>"
      check ("keep-me", rNotAllowedTag) in seen
      check ("drop-me", rNotAllowedTag) in seen

  test "11 on_filter_url rewrites":
    # The hardest shape: the callback RETURNS a string whose ownership passes
    # to the sanitizer core.
    withSanitizer s:
      s.onFilterUrl(proc (elem: Node, raw, resolved: string): string =
        if resolved == "https://example.com/logo.png":
          "https://cdn.example.net/logo.png"
        else:
          resolved)
      check s.sanitize("""<img src="logo.png">""", "https://example.com") ==
        """<img src="https://cdn.example.net/logo.png">"""

  test "11b on_filter_url no-op returns resolved unchanged":
    # Returning `resolved` verbatim is the ABI's "no rewrite" signal and must
    # not corrupt or drop the URL.
    withSanitizer s:
      var calls = 0
      s.onFilterUrl(proc (elem: Node, raw, resolved: string): string =
        inc calls
        resolved)
      check s.sanitize("""<img src="logo.png">""", "https://example.com") ==
        """<img src="https://example.com/logo.png">"""
      check calls > 0

  # ---- 12: handles ----

  test "12 handles are independent":
    withSanitizer a:
      withSanitizer b:
        a.allowedTags.add "only-in-a"
        check "only-in-a" in a.allowedTags
        check "only-in-a" notin b.allowedTags

suite "callback shapes":

  test "on_removing_attribute sees the attribute":
    withSanitizer s:
      var seen: seq[(string, string, string)] = @[]
      s.onRemovingAttribute(proc (elem: Node, attr: Attribute,
                                  reason: Reason): bool =
        seen.add (elem.name, attr.name, attr.value)
        false)                      # false = proceed with the removal
      check s.sanitize("""<div onclick="alert(1)">x</div>""") == "<div>x</div>"
      check ("div", "onclick", "alert(1)") in seen

  test "on_removing_comment cancels":
    withSanitizer s:
      s.onRemovingComment(proc (node: Node): bool = true)
      check s.sanitize("<div>a<!-- keep -->b</div>") == "<div>a<!-- keep -->b</div>"

  test "on_removing_style is four-arg":
    # The odd arity out. If the trampoline's parameter list were wrong, `name`
    # and `value` would be garbage rather than the real property.
    withSanitizer s:
      var seen: seq[(string, string)] = @[]
      s.onRemovingStyle(proc (elem: Node, name, value: string,
                              reason: Reason): bool =
        seen.add (name, value)
        name == "-custom-thing")
      let outp = s.sanitize("""<div style="-custom-thing: 3; color: red">x</div>""")
      check "-custom-thing" in outp
      check ("-custom-thing", "3") in seen

  test "post_process_node visits nodes":
    withSanitizer s:
      var kinds: seq[NodeKind] = @[]
      s.onPostProcessNode(proc (node: Node) = kinds.add node.kind)
      discard s.sanitize("<div><span>a</span><span>b</span></div>")
      check kinds.len > 0

  test "post_process_dom sees the document root":
    withSanitizer s:
      var kind = nkNone
      var childCount = 0
      s.onPostProcessDom(proc (doc: Node) =
        kind = doc.kind
        childCount = doc.childCount)
      discard s.sanitize("<div>a</div><p>b</p>")
      check kind == nkDocument
      check childCount >= 2

  test "node tree navigation from a callback":
    # Exercises children/parent/attributes on borrowed pointers.
    withSanitizer s:
      var tags: seq[string] = @[]
      var sawParent = false
      var attrPairs: seq[(string, string)] = @[]
      s.onPostProcessDom(proc (doc: Node) =
        for c in doc.children:
          if c.kind == nkElement:
            tags.add c.name
            if not c.parent.isNil: sawParent = true
            for a in c.attributes:
              attrPairs.add (a.name, a.value))
      discard s.sanitize("""<div id="one">a</div><p id="two">b</p>""")
      check tags == @["div", "p"]
      check sawParent
      check ("id", "one") in attrPairs
      check ("id", "two") in attrPairs

  test "attr value can be rewritten in place":
    # hs_embed_attr_set_value COPIES core-side, so a transient Nim buffer is
    # safe to hand it.
    withSanitizer s:
      s.onPostProcessNode(proc (node: Node) =
        if node.kind == nkElement and node.name == "a":
          for a in node.attributes:
            if a.name == "href":
              a.value = "https://example.org/safe")
      check s.sanitize("""<a href="https://example.com/x">t</a>""") ==
        """<a href="https://example.org/safe">t</a>"""

  test "clearing a hook restores default behaviour":
    withSanitizer s:
      s.onRemovingTag(proc (node: Node, reason: Reason): bool =
        node.name == "keep-me")
      check s.sanitize("<div><keep-me>a</keep-me></div>") ==
        "<div><keep-me>a</keep-me></div>"
      s.onRemovingTag(nil)
      check s.sanitize("<div><keep-me>a</keep-me></div>") == "<div></div>"

suite "surface":

  test "abi_version is at least 1":
    check abiVersion() >= 1
    withSanitizer s:
      check s.abiVersion >= 1

  test "closed sanitizer rejects use":
    let s = newSanitizer()
    s.close()
    check s.isClosed
    expect HtmlSanitizerError:
      discard s.sanitize("<div>x</div>")
    expect HtmlSanitizerError:
      discard s.allowedTags.len
    s.close()          # idempotent
    check s.isClosed

  test "interior NUL is refused, not truncated":
    # Silently truncating "<div>\0<script>" is how a sanitizer binding becomes
    # a bypass.
    withSanitizer s:
      expect HtmlSanitizerError:
        discard s.sanitize("<div>a\0<script>evil()</script></div>")

  test "sanitize_document is wired":
    withSanitizer s:
      check s.sanitizeDocument("<div>doc<script>x</script></div>") == "<html><head></head><body><div>doc</div></body></html>"

  test "one-shot helpers":
    check sanitize("<div>a<script>b</script></div>") == "<div>a</div>"
    check sanitizeDocument("<div>doc<script>x</script></div>") == "<html><head></head><body><div>doc</div></body></html>"

  test "allow_data_attributes flag":
    withSanitizer s:
      check s.allowDataAttributes == false
      s.allowDataAttributes = true
      check s.allowDataAttributes == true
      check s.sanitize("""<div data-x="1"></div>""") == """<div data-x="1"></div>"""

  test "policy list clear and bulk add":
    withSanitizer s:
      s.allowedSchemes.clear()
      check s.allowedSchemes.len == 0
      s.allowedSchemes.add ["http", "https", "mailto"]
      check s.allowedSchemes.sorted() == @["http", "https", "mailto"]

  test "item_at out of range is an empty string":
    withSanitizer s:
      check s.allowedSchemes[999] == ""

  test "all six policy lists are reachable":
    # Guards the selector constants against a renumbering typo: each list must
    # answer independently.
    withSanitizer s:
      for l in [s.allowedTags, s.allowedAttributes, s.allowedCssProperties,
                s.allowedSchemes, s.allowedClasses, s.uriAttributes]:
        l.add "zz-probe"
        check "zz-probe" in l
        l.excl "zz-probe"
        check "zz-probe" notin l

  test "base url resolution":
    withSanitizer s:
      check s.sanitize("""<img src="logo.png">""", "https://example.com") ==
        """<img src="https://example.com/logo.png">"""

  test "no leak across many string round trips":
    # Not a leak detector, but it does exercise takeString several thousand
    # times; a double-free or a missing free shows up here under valgrind/ASan.
    withSanitizer s:
      for i in 0 ..< 2000:
        check s.sanitize("<div>x<script>y</script></div>") == "<div>x</div>"
