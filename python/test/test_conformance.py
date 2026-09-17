"""The 12-check binding conformance suite (docs/conformance.md).

Proves the Python binding marshals every value shape across the FFI. It is
NOT a sanitizer test suite — the behavioural cases live in the sanitizer core's own
tests and run once, in Aether.
"""

import pytest

from htmlsanitizer import HtmlSanitizer


@pytest.fixture
def s():
    with HtmlSanitizer() as sanitizer:
        yield sanitizer


def test_01_script_removed(s):
    assert s.sanitize("<div>Hello <script>alert(1)</script> world!</div>") == \
        "<div>Hello  world!</div>"


def test_02_onclick_removed(s):
    assert s.sanitize('<div onclick="alert(1)">Hello</div>') == "<div>Hello</div>"


def test_03_empty_string(s):
    assert s.sanitize("") == ""


def test_04_utf8_round_trip(s):
    assert s.sanitize("<div>café ☕</div>") == "<div>café ☕</div>"


def test_05_allow_custom_tag(s):
    assert s.sanitize("<my-widget>x</my-widget>") == ""
    s.allowed_tags.add("my-widget")
    assert s.sanitize("<my-widget>x</my-widget>") == "<my-widget>x</my-widget>"


def test_06_disallow_tag(s):
    assert s.sanitize("<div>x</div>") == "<div>x</div>"
    s.allowed_tags.discard("div")
    assert s.sanitize("<div>x</div>") == ""


def test_07_membership_and_count(s):
    assert "http" in s.allowed_schemes
    assert "gopher" not in s.allowed_schemes
    assert len(s.allowed_schemes) == 2


def test_08_enumeration(s):
    assert sorted(s.allowed_schemes) == ["http", "https"]


def test_09_keep_child_nodes(s):
    assert s.sanitize("<div><nope>Hello <span>world</span></nope></div>") == "<div></div>"
    s.keep_child_nodes = True
    assert s.keep_child_nodes is True
    assert s.sanitize("<div><nope>Hello <span>world</span></nope></div>") == \
        "<div>Hello <span>world</span></div>"


def test_10_on_removing_tag_cancels(s):
    seen = []

    def keep_marked(node, reason):
        seen.append((node.name, reason))
        return node.name == "keep-me"

    s.on_removing_tag(keep_marked)
    out = s.sanitize("<div><keep-me>a</keep-me><drop-me>b</drop-me></div>")
    assert out == "<div><keep-me>a</keep-me></div>"
    assert ("keep-me", 0) in seen
    assert ("drop-me", 0) in seen


def test_11_on_filter_url_rewrites(s):
    def rewrite(node, raw, resolved):
        if resolved == "https://example.com/logo.png":
            return "https://cdn.example.net/logo.png"
        return resolved

    s.on_filter_url(rewrite)
    assert s.sanitize('<img src="logo.png">', "https://example.com") == \
        '<img src="https://cdn.example.net/logo.png">'


def test_12_handles_are_independent():
    with HtmlSanitizer() as a, HtmlSanitizer() as b:
        a.allowed_tags.add("only-in-a")
        assert "only-in-a" in a.allowed_tags
        assert "only-in-a" not in b.allowed_tags


# ---- a few extras that exercise the remaining callback shapes ----

def test_on_removing_attribute_sees_the_attribute(s):
    seen = []

    def watch(elem, attr, reason):
        seen.append((elem.name, attr.name, attr.value))
        return False

    s.on_removing_attribute(watch)
    assert s.sanitize('<div onclick="alert(1)">x</div>') == "<div>x</div>"
    assert ("div", "onclick", "alert(1)") in seen


def test_on_removing_comment_cancels(s):
    s.on_removing_comment(lambda node: True)
    assert s.sanitize("<div>a<!-- keep -->b</div>") == "<div>a<!-- keep -->b</div>"


def test_on_removing_style_is_four_arg(s):
    seen = []

    def watch(elem, name, value, reason):
        seen.append((name, value))
        return name == "-custom-thing"

    s.on_removing_style(watch)
    out = s.sanitize('<div style="-custom-thing: 3; color: red">x</div>')
    assert "-custom-thing" in out
    assert ("-custom-thing", "3") in seen


def test_post_process_node_visits(s):
    count = []
    s.on_post_process_node(lambda node: count.append(node.kind))
    s.sanitize("<div><span>a</span><span>b</span></div>")
    assert len(count) > 0


def test_node_tree_navigation(s):
    captured = {}

    def inspect(doc):
        captured["kind"] = doc.kind
        captured["children"] = len(doc.children)

    s.on_post_process_dom(inspect)
    s.sanitize("<div>a</div><p>b</p>")
    assert captured["kind"] == 1          # NODE_DOCUMENT
    assert captured["children"] >= 2


def test_abi_version(s):
    assert s.abi_version >= 1


def test_closed_sanitizer_rejects_use():
    sanitizer = HtmlSanitizer()
    sanitizer.close()
    with pytest.raises(ValueError):
        sanitizer.sanitize("<div>x</div>")
