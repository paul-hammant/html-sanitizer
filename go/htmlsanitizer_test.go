// The 12-check binding conformance suite (docs/conformance.md).
//
// Proves the Go binding marshals every value shape across the FFI. It is NOT a
// sanitizer test suite — the behavioural cases live in the engine's own tests
// and run once, in Aether.
package htmlsanitizer

import (
	"errors"
	"strings"
	"testing"
)

func newSanitizer(t *testing.T) *Sanitizer {
	t.Helper()
	s, err := New()
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func eq(t *testing.T, what, got, want string) {
	t.Helper()
	if got != want {
		t.Errorf("%s:\n  got  %q\n  want %q", what, got, want)
	}
}

func Test01ScriptRemoved(t *testing.T) {
	s := newSanitizer(t)
	eq(t, "script removed",
		s.Sanitize("<div>Hello <script>alert(1)</script> world!</div>", ""),
		"<div>Hello  world!</div>")
}

func Test02OnclickRemoved(t *testing.T) {
	s := newSanitizer(t)
	eq(t, "onclick removed", s.Sanitize(`<div onclick="alert(1)">Hello</div>`, ""),
		"<div>Hello</div>")
}

func Test03EmptyString(t *testing.T) {
	s := newSanitizer(t)
	eq(t, "empty string", s.Sanitize("", ""), "")
}

func Test04UTF8RoundTrip(t *testing.T) {
	s := newSanitizer(t)
	eq(t, "utf-8 round trip", s.Sanitize("<div>café ☕</div>", ""), "<div>café ☕</div>")
}

func Test05AllowCustomTag(t *testing.T) {
	s := newSanitizer(t)
	eq(t, "unknown tag dropped", s.Sanitize("<my-widget>x</my-widget>", ""), "")
	s.AllowedTags.Add("my-widget")
	eq(t, "custom tag kept", s.Sanitize("<my-widget>x</my-widget>", ""),
		"<my-widget>x</my-widget>")
}

func Test06DisallowTag(t *testing.T) {
	s := newSanitizer(t)
	eq(t, "div kept by default", s.Sanitize("<div>x</div>", ""), "<div>x</div>")
	s.AllowedTags.Remove("div")
	eq(t, "div now stripped", s.Sanitize("<div>x</div>", ""), "")
}

func Test07MembershipAndCount(t *testing.T) {
	s := newSanitizer(t)
	if !s.AllowedSchemes.Contains("http") {
		t.Error("expected http in AllowedSchemes")
	}
	if s.AllowedSchemes.Contains("gopher") {
		t.Error("did not expect gopher in AllowedSchemes")
	}
	if got := s.AllowedSchemes.Len(); got != 2 {
		t.Errorf("AllowedSchemes.Len() = %d, want 2", got)
	}
}

func Test08Enumeration(t *testing.T) {
	s := newSanitizer(t)
	got := strings.Join(s.AllowedSchemes.Sorted(), ",")
	eq(t, "enumerated schemes", got, "http,https")
}

func Test09KeepChildNodes(t *testing.T) {
	s := newSanitizer(t)
	eq(t, "subtree dropped", s.Sanitize("<div><nope>Hello <span>world</span></nope></div>", ""),
		"<div></div>")
	s.SetKeepChildNodes(true)
	if !s.KeepChildNodes() {
		t.Error("KeepChildNodes() = false after SetKeepChildNodes(true)")
	}
	eq(t, "children kept", s.Sanitize("<div><nope>Hello <span>world</span></nope></div>", ""),
		"<div>Hello <span>world</span></div>")
}

func Test10OnRemovingTagCancels(t *testing.T) {
	s := newSanitizer(t)
	type seenTag struct {
		name   string
		reason Reason
	}
	var seen []seenTag

	s.OnRemovingTag(func(node Node, reason Reason) bool {
		seen = append(seen, seenTag{node.Name(), reason})
		return node.Name() == "keep-me"
	})

	eq(t, "on_removing_tag cancels selectively",
		s.Sanitize("<div><keep-me>a</keep-me><drop-me>b</drop-me></div>", ""),
		"<div><keep-me>a</keep-me></div>")

	want := map[string]bool{"keep-me": false, "drop-me": false}
	for _, v := range seen {
		if v.reason != ReasonNotAllowedTag {
			t.Errorf("reason for %q = %d, want %d", v.name, v.reason, ReasonNotAllowedTag)
		}
		want[v.name] = true
	}
	for name, ok := range want {
		if !ok {
			t.Errorf("callback never saw %q", name)
		}
	}
}

func Test11OnFilterURLRewrites(t *testing.T) {
	s := newSanitizer(t)
	s.OnFilterURL(func(_ Node, _, resolved string) string {
		if resolved == "https://example.com/logo.png" {
			return "https://cdn.example.net/logo.png"
		}
		return resolved
	})

	eq(t, "on_filter_url rewrites",
		s.Sanitize(`<img src="logo.png">`, "https://example.com"),
		`<img src="https://cdn.example.net/logo.png">`)
}

func Test12HandlesAreIndependent(t *testing.T) {
	a := newSanitizer(t)
	b := newSanitizer(t)
	a.AllowedTags.Add("only-in-a")
	if !a.AllowedTags.Contains("only-in-a") {
		t.Error("handle a should know the tag")
	}
	if b.AllowedTags.Contains("only-in-a") {
		t.Error("handle b should NOT know the tag")
	}
}

// ---- a few extras that exercise the remaining callback shapes ----

func TestOnRemovingAttributeSeesTheAttribute(t *testing.T) {
	s := newSanitizer(t)
	var seen []string

	s.OnRemovingAttribute(func(elem Node, attr Attribute, _ Reason) bool {
		seen = append(seen, elem.Name()+"|"+attr.Name()+"|"+attr.Value())
		return false
	})

	eq(t, "attribute still removed", s.Sanitize(`<div onclick="alert(1)">x</div>`, ""),
		"<div>x</div>")
	if !contains(seen, "div|onclick|alert(1)") {
		t.Errorf("callback saw %v, want div|onclick|alert(1)", seen)
	}
}

func TestOnRemovingCommentCancels(t *testing.T) {
	s := newSanitizer(t)
	s.OnRemovingComment(func(Node) bool { return true })
	eq(t, "comment kept", s.Sanitize("<div>a<!-- keep -->b</div>", ""),
		"<div>a<!-- keep -->b</div>")
}

func TestOnRemovingStyleIsFourArg(t *testing.T) {
	s := newSanitizer(t)
	var seen []string

	s.OnRemovingStyle(func(_ Node, name, value string, _ Reason) bool {
		seen = append(seen, name+"|"+value)
		return name == "-custom-thing"
	})

	out := s.Sanitize(`<div style="-custom-thing: 3; color: red">x</div>`, "")
	if !strings.Contains(out, "-custom-thing") {
		t.Errorf("expected the cancelled property to survive, got %q", out)
	}
	if !contains(seen, "-custom-thing|3") {
		t.Errorf("callback saw %v, want -custom-thing|3", seen)
	}
}

func TestPostProcessNodeVisits(t *testing.T) {
	s := newSanitizer(t)
	var kinds []Kind
	s.OnPostProcessNode(func(n Node) { kinds = append(kinds, n.Kind()) })
	s.Sanitize("<div><span>a</span><span>b</span></div>", "")
	if len(kinds) == 0 {
		t.Error("post_process_node never fired")
	}
}

func TestNodeTreeNavigation(t *testing.T) {
	s := newSanitizer(t)
	var kind Kind
	children := -1

	s.OnPostProcessDOM(func(doc Node) {
		kind = doc.Kind()
		children = len(doc.Children())
	})

	s.Sanitize("<div>a</div><p>b</p>", "")
	if kind != KindDocument {
		t.Errorf("doc kind = %d, want %d", kind, KindDocument)
	}
	if children < 2 {
		t.Errorf("doc children = %d, want >= 2", children)
	}
}

func TestNodeParentAndAttributes(t *testing.T) {
	s := newSanitizer(t)
	var sawParent, sawAttr bool

	s.OnPostProcessNode(func(n Node) {
		if n.Kind() != KindElement || n.Name() != "a" {
			return
		}
		if _, ok := n.Parent(); ok {
			sawParent = true
		}
		for _, a := range n.Attributes() {
			if a.Name() == "href" && a.Value() != "" {
				sawAttr = true
			}
		}
	})

	s.Sanitize(`<div><a href="https://example.com/">x</a></div>`, "")
	if !sawParent {
		t.Error("expected the <a> element to have a parent")
	}
	if !sawAttr {
		t.Error("expected to read the href attribute")
	}
}

func TestAttributeSetValue(t *testing.T) {
	s := newSanitizer(t)
	s.OnRemovingAttribute(func(_ Node, attr Attribute, _ Reason) bool {
		attr.SetValue("scrubbed")
		return false
	})
	eq(t, "attribute still removed after rewrite",
		s.Sanitize(`<div onclick="alert(1)">x</div>`, ""), "<div>x</div>")
}

func TestClearingAHookRestoresDefaults(t *testing.T) {
	s := newSanitizer(t)
	s.OnRemovingTag(func(node Node, _ Reason) bool { return node.Name() == "keep-me" })
	eq(t, "hook active", s.Sanitize("<div><keep-me>a</keep-me></div>", ""),
		"<div><keep-me>a</keep-me></div>")
	s.OnRemovingTag(nil)
	eq(t, "hook cleared", s.Sanitize("<div><keep-me>a</keep-me></div>", ""), "<div></div>")
}

func TestSanitizeDocument(t *testing.T) {
	s := newSanitizer(t)
	eq(t, "sanitize_document", s.SanitizeDocument("<div>doc<script>x</script></div>", ""),
		"<html><head></head><body><div>doc</div></body></html>")
}

func TestAllowDataAttributes(t *testing.T) {
	s := newSanitizer(t)
	s.SetAllowDataAttributes(true)
	if !s.AllowDataAttributes() {
		t.Error("AllowDataAttributes() = false after setting it")
	}
	eq(t, "data-* kept", s.Sanitize(`<div data-x="1"></div>`, ""), `<div data-x="1"></div>`)
}

func TestClearPolicyList(t *testing.T) {
	s := newSanitizer(t)
	s.AllowedSchemes.Clear()
	if got := s.AllowedSchemes.Len(); got != 0 {
		t.Errorf("AllowedSchemes.Len() after Clear = %d, want 0", got)
	}
}

func TestABIVersion(t *testing.T) {
	if got := ABIVersion(); got < 1 {
		t.Errorf("ABIVersion() = %d, want >= 1", got)
	}
}

func TestClosedSanitizerRejectsUse(t *testing.T) {
	s, err := New()
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	s.Close()
	if _, err := s.SanitizeErr("<div>x</div>", ""); !errors.Is(err, ErrClosed) {
		t.Errorf("SanitizeErr after Close = %v, want ErrClosed", err)
	}
	s.Close() // idempotent
}

func TestPackageLevelSanitize(t *testing.T) {
	out, err := Sanitize("<div>a<script>b</script></div>", "")
	if err != nil {
		t.Fatalf("Sanitize: %v", err)
	}
	eq(t, "package-level Sanitize", out, "<div>a</div>")
}

// Callbacks fire on the engine's C stack via cgo.Handle. Running many
// sanitizers with hooks installed catches a handle registry that leaks or
// resolves to the wrong owner.
func TestCallbacksResolveTheRightOwner(t *testing.T) {
	for i := 0; i < 50; i++ {
		a, _ := New()
		b, _ := New()
		a.OnRemovingTag(func(Node, Reason) bool { return true })
		b.OnRemovingTag(func(Node, Reason) bool { return false })

		eq(t, "owner a keeps", a.Sanitize("<div><nope>x</nope></div>", ""),
			"<div><nope>x</nope></div>")
		eq(t, "owner b drops", b.Sanitize("<div><nope>x</nope></div>", ""), "<div></div>")
		a.Close()
		b.Close()
	}
}

func contains(hay []string, needle string) bool {
	for _, h := range hay {
		if h == needle {
			return true
		}
	}
	return false
}
