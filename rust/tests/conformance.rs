//! The 12-check binding conformance suite (docs/conformance.md).
//!
//! Proves the Rust binding marshals every value shape across the FFI. It is
//! NOT a sanitizer test suite — the behavioural cases live in the engine's own
//! tests and run once, in Aether.

use std::cell::RefCell;
use std::rc::Rc;

use htmlsanitizer::HtmlSanitizer;

fn s() -> HtmlSanitizer {
    HtmlSanitizer::new().expect("load the engine (set HTMLSANITIZER_LIB)")
}

#[test]
fn t01_script_removed() {
    assert_eq!(
        s().sanitize("<div>Hello <script>alert(1)</script> world!</div>"),
        "<div>Hello  world!</div>"
    );
}

#[test]
fn t02_onclick_removed() {
    assert_eq!(
        s().sanitize(r#"<div onclick="alert(1)">Hello</div>"#),
        "<div>Hello</div>"
    );
}

#[test]
fn t03_empty_string() {
    assert_eq!(s().sanitize(""), "");
}

#[test]
fn t04_utf8_round_trip() {
    assert_eq!(s().sanitize("<div>café ☕</div>"), "<div>café ☕</div>");
}

#[test]
fn t05_allow_custom_tag() {
    let s = s();
    assert_eq!(s.sanitize("<my-widget>x</my-widget>"), "");
    s.allowed_tags().add("my-widget");
    assert_eq!(
        s.sanitize("<my-widget>x</my-widget>"),
        "<my-widget>x</my-widget>"
    );
}

#[test]
fn t06_disallow_tag() {
    let s = s();
    assert_eq!(s.sanitize("<div>x</div>"), "<div>x</div>");
    s.allowed_tags().remove("div");
    assert_eq!(s.sanitize("<div>x</div>"), "");
}

#[test]
fn t07_membership_and_count() {
    let s = s();
    assert!(s.allowed_schemes().contains("http"));
    assert!(!s.allowed_schemes().contains("gopher"));
    assert_eq!(s.allowed_schemes().len(), 2);
}

#[test]
fn t08_enumeration() {
    let s = s();
    let mut got = s.allowed_schemes().to_vec();
    got.sort();
    assert_eq!(got, vec!["http".to_string(), "https".to_string()]);
}

#[test]
fn t09_keep_child_nodes() {
    let mut s = s();
    assert_eq!(
        s.sanitize("<div><nope>Hello <span>world</span></nope></div>"),
        "<div></div>"
    );
    s.set_keep_child_nodes(true);
    assert!(s.keep_child_nodes());
    assert_eq!(
        s.sanitize("<div><nope>Hello <span>world</span></nope></div>"),
        "<div>Hello <span>world</span></div>"
    );
}

#[test]
fn t10_on_removing_tag_cancels() {
    let mut s = s();
    let seen = Rc::new(RefCell::new(Vec::new()));
    let sink = Rc::clone(&seen);
    s.on_removing_tag(move |node, reason| {
        let name = node.name();
        sink.borrow_mut().push((name.clone(), reason));
        name == "keep-me"
    });
    let out = s.sanitize("<div><keep-me>a</keep-me><drop-me>b</drop-me></div>");
    assert_eq!(out, "<div><keep-me>a</keep-me></div>");
    let seen = seen.borrow();
    assert!(seen.contains(&("keep-me".to_string(), 0)), "{seen:?}");
    assert!(seen.contains(&("drop-me".to_string(), 0)), "{seen:?}");
}

#[test]
fn t11_on_filter_url_rewrites() {
    let mut s = s();
    s.on_filter_url(|_node, _raw, resolved| {
        if resolved == "https://example.com/logo.png" {
            "https://cdn.example.net/logo.png".to_string()
        } else {
            resolved.to_string()
        }
    });
    assert_eq!(
        s.sanitize_with_base(r#"<img src="logo.png">"#, "https://example.com"),
        r#"<img src="https://cdn.example.net/logo.png">"#
    );
}

#[test]
fn t12_handles_are_independent() {
    let a = s();
    let b = s();
    a.allowed_tags().add("only-in-a");
    assert!(a.allowed_tags().contains("only-in-a"));
    assert!(!b.allowed_tags().contains("only-in-a"));
}

// ---- a few extras that exercise the remaining callback shapes ----

#[test]
fn on_removing_attribute_sees_the_attribute() {
    let mut s = s();
    let seen = Rc::new(RefCell::new(Vec::new()));
    let sink = Rc::clone(&seen);
    s.on_removing_attribute(move |elem, attr, _reason| {
        sink.borrow_mut()
            .push((elem.name(), attr.name(), attr.value()));
        false
    });
    assert_eq!(s.sanitize(r#"<div onclick="alert(1)">x</div>"#), "<div>x</div>");
    let seen = seen.borrow();
    assert!(
        seen.contains(&(
            "div".to_string(),
            "onclick".to_string(),
            "alert(1)".to_string()
        )),
        "{seen:?}"
    );
}

#[test]
fn on_removing_comment_cancels() {
    let mut s = s();
    s.on_removing_comment(|_node| true);
    assert_eq!(
        s.sanitize("<div>a<!-- keep -->b</div>"),
        "<div>a<!-- keep -->b</div>"
    );
}

#[test]
fn on_removing_style_is_four_arg() {
    let mut s = s();
    let seen = Rc::new(RefCell::new(Vec::new()));
    let sink = Rc::clone(&seen);
    s.on_removing_style(move |_elem, name, value, _reason| {
        sink.borrow_mut().push((name.to_string(), value.to_string()));
        name == "-custom-thing"
    });
    let out = s.sanitize(r#"<div style="-custom-thing: 3; color: red">x</div>"#);
    assert!(out.contains("-custom-thing"), "{out}");
    let seen = seen.borrow();
    assert!(
        seen.contains(&("-custom-thing".to_string(), "3".to_string())),
        "{seen:?}"
    );
}

#[test]
fn post_process_node_visits() {
    let mut s = s();
    let kinds = Rc::new(RefCell::new(Vec::new()));
    let sink = Rc::clone(&kinds);
    s.on_post_process_node(move |node| sink.borrow_mut().push(node.kind()));
    s.sanitize("<div><span>a</span><span>b</span></div>");
    assert!(!kinds.borrow().is_empty());
}

#[test]
fn node_tree_navigation() {
    let mut s = s();
    let captured = Rc::new(RefCell::new((0i32, 0usize)));
    let sink = Rc::clone(&captured);
    s.on_post_process_dom(move |doc| {
        *sink.borrow_mut() = (doc.kind(), doc.children().len());
    });
    s.sanitize("<div>a</div><p>b</p>");
    let (kind, children) = *captured.borrow();
    assert_eq!(kind, htmlsanitizer::NODE_DOCUMENT);
    assert!(children >= 2, "children={children}");
}

#[test]
fn abi_version() {
    assert!(s().abi_version() >= 1);
}

#[test]
fn sanitize_document_is_wired() {
    assert_eq!(
        s().sanitize_document("<div>doc<script>x</script></div>"),
        "<div>doc</div>"
    );
}
