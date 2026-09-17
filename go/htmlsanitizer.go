// Package htmlsanitizer cleans HTML of constructs that can lead to
// Cross-Site Scripting (XSS).
//
// It is a thin cgo binding over the monorepo's ONE shared native sanitizer core
// (core/native/libhtmlsanitizer.so, compiled from pure Aether). No sanitizer
// logic lives in this package — every method marshals to an
// `aether_hs_embed_*` call across the C ABI described in core/embed.ae.
//
//	s, err := htmlsanitizer.New()
//	if err != nil { ... }
//	defer s.Close()
//	clean := s.Sanitize(`<div onclick="alert(1)">hi</div>`, "")
//	// clean == "<div>hi</div>"
package htmlsanitizer

/*
#cgo LDFLAGS: -L${SRCDIR}/native -L${SRCDIR}/../core/native -lhtmlsanitizer -Wl,-rpath,${SRCDIR}/native -Wl,-rpath,${SRCDIR}/../core/native

#include <stdlib.h>
#include <stdint.h>
#include "bridge.h"

// ---- the C ABI (core/embed.ae). Declared, not defined: we LINK the sanitizer core
// rather than dlopen it, so cgo resolves these at build time. ----

void* aether_hs_embed_new(void);
void  aether_hs_embed_free(void* h);
void  aether_hs_embed_free_string(char* s);
char* aether_hs_embed_sanitize(void* h, const char* html, const char* base_url);
char* aether_hs_embed_sanitize_document(void* h, const char* html, const char* base_url);
void  aether_hs_embed_set_keep_child_nodes(void* h, int on);
int   aether_hs_embed_get_keep_child_nodes(void* h);
void  aether_hs_embed_set_allow_data_attributes(void* h, int on);
int   aether_hs_embed_get_allow_data_attributes(void* h);
int   aether_hs_embed_allow(void* h, int which, const char* item);
int   aether_hs_embed_disallow(void* h, int which, const char* item);
int   aether_hs_embed_is_allowed(void* h, int which, const char* item);
int   aether_hs_embed_clear(void* h, int which);
int   aether_hs_embed_count(void* h, int which);
char* aether_hs_embed_item_at(void* h, int which, int index);
int   aether_hs_embed_abi_version(void);
void  aether_hs_embed_on_removing_tag(void* h, void* fn, void* ud);
void  aether_hs_embed_on_removing_attribute(void* h, void* fn, void* ud);
void  aether_hs_embed_on_removing_style(void* h, void* fn, void* ud);
void  aether_hs_embed_on_removing_comment(void* h, void* fn, void* ud);
void  aether_hs_embed_on_post_process_node(void* h, void* fn, void* ud);
void  aether_hs_embed_on_post_process_dom(void* h, void* fn, void* ud);
void  aether_hs_embed_on_filter_url(void* h, void* fn, void* ud);
int   aether_hs_embed_node_kind(void* n);
char* aether_hs_embed_node_name(void* n);
char* aether_hs_embed_node_value(void* n);
int   aether_hs_embed_node_child_count(void* n);
void* aether_hs_embed_node_child_at(void* n, int index);
void* aether_hs_embed_node_parent(void* n);
int   aether_hs_embed_node_attr_count(void* n);
void* aether_hs_embed_node_attr_at(void* n, int index);
char* aether_hs_embed_attr_name(void* a);
char* aether_hs_embed_attr_value(void* a);
void  aether_hs_embed_attr_set_value(void* a, const char* value);
*/
import "C"

import (
	"errors"
	"runtime"
	"runtime/cgo"
	"sort"
	"unsafe"
)

// Which selects one of the sanitizer core's six policy lists. These are ABI constants
// — append only, never renumber.
type Which int

const (
	Tags          Which = 0
	Attributes    Which = 1
	CSSProperties Which = 2
	Schemes       Which = 3
	Classes       Which = 4
	URIAttributes Which = 5
)

// Reason is why the sanitizer core is about to remove something, as handed to the
// removing_* callbacks.
type Reason int

const (
	ReasonNotAllowedTag       Reason = 0
	ReasonNotAllowedAttribute Reason = 1
	ReasonNotAllowedStyle     Reason = 2
	ReasonNotAllowedURLValue  Reason = 3
	ReasonNotAllowedValue     Reason = 4
	ReasonNotAllowedCSSClass  Reason = 5
	ReasonClassAttributeEmpty Reason = 6
	ReasonStyleAttributeEmpty Reason = 7
)

// Kind is a DOM node's type.
type Kind int

const (
	KindDocument Kind = 1
	KindElement  Kind = 2
	KindText     Kind = 3
	KindComment  Kind = 4
)

// ErrClosed is returned by ABI-touching methods after Close.
var ErrClosed = errors.New("htmlsanitizer: sanitizer is closed")

// lib is a placeholder for the "which library" dimension the dlopen-based
// bindings carry. Here the sanitizer core is LINKED, so there is exactly one, and this
// type exists only so Node/Attribute have the same shape across bindings.
type lib struct{}

var theLib = &lib{}

// takeString copies an ABI-returned string out and frees it through the ABI.
//
// Every char* the sanitizer core returns is caller-owned; leaking it is the single
// easiest mistake to make in any of these bindings, so every string result in
// this file goes through here.
func takeString(s *C.char) string {
	if s == nil {
		return ""
	}
	defer C.aether_hs_embed_free_string(s)
	return C.GoString(s)
}

// ---- Attribute ----

// Attribute is a DOM attribute, borrowed for the duration of a callback.
//
// Do not retain one past the callback that gave it to you — the DOM is freed
// when Sanitize returns.
type Attribute struct {
	lib *lib
	ptr unsafe.Pointer
}

// Name is the attribute's name.
func (a Attribute) Name() string { return takeString(C.aether_hs_embed_attr_name(a.ptr)) }

// Value is the attribute's current value.
func (a Attribute) Value() string { return takeString(C.aether_hs_embed_attr_value(a.ptr)) }

// SetValue rewrites the attribute in place — e.g. to canonicalise a URL
// rather than remove the attribute outright.
func (a Attribute) SetValue(v string) {
	cv := C.CString(v)
	defer C.free(unsafe.Pointer(cv))
	C.aether_hs_embed_attr_set_value(a.ptr, cv)
}

// ---- Node ----

// Node is a DOM node, borrowed for the duration of a callback.
type Node struct {
	lib *lib
	ptr unsafe.Pointer
}

// Kind reports the node type (Document, Element, Text or Comment).
func (n Node) Kind() Kind { return Kind(C.aether_hs_embed_node_kind(n.ptr)) }

// Name is the element's lowercased tag name; "" for non-elements.
func (n Node) Name() string { return takeString(C.aether_hs_embed_node_name(n.ptr)) }

// Value is text/comment content; "" for elements and documents.
func (n Node) Value() string { return takeString(C.aether_hs_embed_node_value(n.ptr)) }

// Parent returns the parent node and whether there was one.
func (n Node) Parent() (Node, bool) {
	p := C.aether_hs_embed_node_parent(n.ptr)
	if p == nil {
		return Node{}, false
	}
	return Node{lib: n.lib, ptr: p}, true
}

// Children returns the node's child nodes.
func (n Node) Children() []Node {
	count := int(C.aether_hs_embed_node_child_count(n.ptr))
	out := make([]Node, 0, count)
	for i := 0; i < count; i++ {
		out = append(out, Node{lib: n.lib, ptr: C.aether_hs_embed_node_child_at(n.ptr, C.int(i))})
	}
	return out
}

// Attributes returns the element's attributes.
func (n Node) Attributes() []Attribute {
	count := int(C.aether_hs_embed_node_attr_count(n.ptr))
	out := make([]Attribute, 0, count)
	for i := 0; i < count; i++ {
		out = append(out, Attribute{lib: n.lib, ptr: C.aether_hs_embed_node_attr_at(n.ptr, C.int(i))})
	}
	return out
}

// ---- AllowList ----

// AllowList is a set-like view over one of the sanitizer core's six policy lists.
// It holds no state of its own — every method reads or writes the sanitizer core.
type AllowList struct {
	s     *Sanitizer
	which Which
}

// Add puts item in the list.
func (l AllowList) Add(items ...string) AllowList {
	for _, item := range items {
		ci := C.CString(item)
		C.aether_hs_embed_allow(l.s.h, C.int(l.which), ci)
		C.free(unsafe.Pointer(ci))
	}
	return l
}

// Remove takes item out of the list (the "deny" direction — e.g. drop "a"
// from AllowedTags).
func (l AllowList) Remove(items ...string) AllowList {
	for _, item := range items {
		ci := C.CString(item)
		C.aether_hs_embed_disallow(l.s.h, C.int(l.which), ci)
		C.free(unsafe.Pointer(ci))
	}
	return l
}

// Clear empties the list — the "start from nothing" move for a caller who
// wants a strict allow-list rather than the permissive defaults.
func (l AllowList) Clear() AllowList {
	C.aether_hs_embed_clear(l.s.h, C.int(l.which))
	return l
}

// Contains reports whether item is currently in the list.
func (l AllowList) Contains(item string) bool {
	ci := C.CString(item)
	defer C.free(unsafe.Pointer(ci))
	return C.aether_hs_embed_is_allowed(l.s.h, C.int(l.which), ci) != 0
}

// Len is the number of entries.
func (l AllowList) Len() int { return int(C.aether_hs_embed_count(l.s.h, C.int(l.which))) }

// Items enumerates the list. Order is unspecified but stable between
// mutations; use Sorted for a deterministic order.
func (l AllowList) Items() []string {
	n := l.Len()
	out := make([]string, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, takeString(C.aether_hs_embed_item_at(l.s.h, C.int(l.which), C.int(i))))
	}
	return out
}

// Sorted is Items, lexicographically ordered.
func (l AllowList) Sorted() []string {
	out := l.Items()
	sort.Strings(out)
	return out
}

// ---- callback signatures ----

// RemovingTagFunc is called before a disallowed tag is removed. Return true to
// CANCEL the removal (keep the node).
type RemovingTagFunc func(node Node, reason Reason) bool

// RemovingAttributeFunc is called before a disallowed attribute is removed.
// Return true to CANCEL the removal.
type RemovingAttributeFunc func(elem Node, attr Attribute, reason Reason) bool

// RemovingStyleFunc is called before a disallowed CSS property is removed.
// Return true to CANCEL the removal.
type RemovingStyleFunc func(elem Node, name, value string, reason Reason) bool

// RemovingCommentFunc is called before a comment is removed. Return true to
// CANCEL the removal.
type RemovingCommentFunc func(node Node) bool

// PostProcessFunc observes a node (or the whole document) after filtering.
type PostProcessFunc func(node Node)

// FilterURLFunc rewrites a URL. Return resolved unchanged for "no rewrite",
// or "" to drop the attribute.
type FilterURLFunc func(elem Node, raw, resolved string) string

// ---- Sanitizer ----

// Sanitizer cleans HTML of constructs that can lead to XSS. It wraps one
// native handle; create it with New and release it with Close.
//
// A Sanitizer is NOT safe for concurrent use: the native handle carries
// mutable policy and hook state. Use one per goroutine, or guard it.
type Sanitizer struct {
	h      unsafe.Pointer
	lib    *lib
	handle cgo.Handle   // the token the sanitizer core hands back as user_data
	udCell *C.uintptr_t // C-allocated cell holding that token

	// Registered hooks. Held on the Go side (never passed to C) and kept
	// alive for exactly as long as the native handle can call them — the Go
	// equivalent of the other bindings' "keepalive" list.
	onRemovingTag       RemovingTagFunc
	onRemovingAttribute RemovingAttributeFunc
	onRemovingStyle     RemovingStyleFunc
	onRemovingComment   RemovingCommentFunc
	onPostProcessNode   PostProcessFunc
	onPostProcessDOM    PostProcessFunc
	onFilterURL         FilterURLFunc

	// Policy lists, pre-bound so callers write s.AllowedTags.Add("x").
	AllowedTags          AllowList
	AllowedAttributes    AllowList
	AllowedCSSProperties AllowList
	AllowedSchemes       AllowList
	AllowedClasses       AllowList
	URIAttributes        AllowList
}

// New creates a sanitizer with the sanitizer core's secure defaults populated.
// Call Close (typically via defer) to release the native handle.
func New() (*Sanitizer, error) {
	h := C.aether_hs_embed_new()
	if h == nil {
		return nil, errors.New("htmlsanitizer: failed to create the native sanitizer")
	}
	s := &Sanitizer{h: h, lib: theLib}
	// cgo.Handle gives the sanitizer core an integer token for this object. Passing
	// &s (a Go pointer) through C would violate the cgo pointer rules and can
	// be caught by the runtime or invalidated by a moving GC. The token then
	// lives in a malloc'd cell (see ud) so the ABI's void* is a real C pointer.
	s.handle = cgo.NewHandle(s)
	cell := (*C.uintptr_t)(C.malloc(C.size_t(unsafe.Sizeof(C.uintptr_t(0)))))
	if cell == nil {
		s.handle.Delete()
		C.aether_hs_embed_free(h)
		return nil, errors.New("htmlsanitizer: out of memory allocating the callback cell")
	}
	*cell = C.uintptr_t(s.handle)
	s.udCell = cell

	s.AllowedTags = AllowList{s, Tags}
	s.AllowedAttributes = AllowList{s, Attributes}
	s.AllowedCSSProperties = AllowList{s, CSSProperties}
	s.AllowedSchemes = AllowList{s, Schemes}
	s.AllowedClasses = AllowList{s, Classes}
	s.URIAttributes = AllowList{s, URIAttributes}

	// A dropped Sanitizer would otherwise leak both the native handle and the
	// cgo.Handle slot; Close remains the documented, deterministic way.
	runtime.SetFinalizer(s, func(x *Sanitizer) { x.Close() })
	return s, nil
}

// Close releases the native handle. It is safe to call more than once.
func (s *Sanitizer) Close() error {
	if s == nil || s.h == nil {
		return nil
	}
	C.aether_hs_embed_free(s.h)
	s.h = nil
	s.handle.Delete()
	s.handle = 0
	if s.udCell != nil {
		C.free(unsafe.Pointer(s.udCell))
		s.udCell = nil
	}
	s.onRemovingTag = nil
	s.onRemovingAttribute = nil
	s.onRemovingStyle = nil
	s.onRemovingComment = nil
	s.onPostProcessNode = nil
	s.onPostProcessDOM = nil
	s.onFilterURL = nil
	runtime.SetFinalizer(s, nil)
	return nil
}

// Closed reports whether Close has been called.
func (s *Sanitizer) Closed() bool { return s == nil || s.h == nil }

// ud is this sanitizer's user_data: a pointer to a C-allocated cell holding
// the cgo.Handle token.
//
// The obvious `unsafe.Pointer(uintptr(s.handle))` is NOT valid Go — converting
// an integer to unsafe.Pointer is pointer arithmetic on a bad value, and
// -race / -d=checkptr aborts the process on it. Storing the token in malloc'd
// memory keeps the ABI's void* a genuine C pointer, and keeps every Go pointer
// on the Go side, as the cgo rules require.
func (s *Sanitizer) ud() unsafe.Pointer { return unsafe.Pointer(s.udCell) }

// ---- the main entry point ----

// Sanitize cleans an HTML fragment. baseURL may be "" (no resolution of
// relative URLs). It returns "" once the sanitizer is closed; use SanitizeErr
// if you need that distinguished from an empty result.
func (s *Sanitizer) Sanitize(html, baseURL string) string {
	out, _ := s.SanitizeErr(html, baseURL)
	return out
}

// SanitizeErr is Sanitize, reporting ErrClosed rather than returning "".
func (s *Sanitizer) SanitizeErr(html, baseURL string) (string, error) {
	if s.Closed() {
		return "", ErrClosed
	}
	ch, cb := C.CString(html), C.CString(baseURL)
	defer C.free(unsafe.Pointer(ch))
	defer C.free(unsafe.Pointer(cb))
	out := takeString(C.aether_hs_embed_sanitize(s.h, ch, cb))
	// Keep s reachable across the C call: the sanitizer core may invoke callbacks
	// that resolve s.handle, and nothing else in this frame references s.
	runtime.KeepAlive(s)
	return out, nil
}

// SanitizeDocument cleans a whole HTML document.
func (s *Sanitizer) SanitizeDocument(html, baseURL string) string {
	out, _ := s.SanitizeDocumentErr(html, baseURL)
	return out
}

// SanitizeDocumentErr is SanitizeDocument, reporting ErrClosed.
func (s *Sanitizer) SanitizeDocumentErr(html, baseURL string) (string, error) {
	if s.Closed() {
		return "", ErrClosed
	}
	ch, cb := C.CString(html), C.CString(baseURL)
	defer C.free(unsafe.Pointer(ch))
	defer C.free(unsafe.Pointer(cb))
	out := takeString(C.aether_hs_embed_sanitize_document(s.h, ch, cb))
	runtime.KeepAlive(s)
	return out, nil
}

// ---- flags ----

// KeepChildNodes reports whether children of a removed element are kept.
func (s *Sanitizer) KeepChildNodes() bool {
	return C.aether_hs_embed_get_keep_child_nodes(s.h) != 0
}

// SetKeepChildNodes keeps the children of a removed element instead of
// dropping the whole subtree.
func (s *Sanitizer) SetKeepChildNodes(on bool) *Sanitizer {
	C.aether_hs_embed_set_keep_child_nodes(s.h, cInt(on))
	return s
}

// AllowDataAttributes reports whether data-* attributes pass unlisted.
func (s *Sanitizer) AllowDataAttributes() bool {
	return C.aether_hs_embed_get_allow_data_attributes(s.h) != 0
}

// SetAllowDataAttributes lets data-* attributes through without listing each.
func (s *Sanitizer) SetAllowDataAttributes(on bool) *Sanitizer {
	C.aether_hs_embed_set_allow_data_attributes(s.h, cInt(on))
	return s
}

// ABIVersion is the sanitizer core's ABI revision.
func ABIVersion() int { return int(C.aether_hs_embed_abi_version()) }

// ABIVersion is the sanitizer core's ABI revision.
func (s *Sanitizer) ABIVersion() int { return ABIVersion() }

func cInt(b bool) C.int {
	if b {
		return 1
	}
	return 0
}

// ---- callbacks ----
//
// Each On* stores the Go func on the Sanitizer and registers the matching C
// trampoline (bridge.h / bridge.go) with this sanitizer's cgo.Handle as
// user_data. Passing nil clears the hook. Each returns the Sanitizer, so they
// chain.

// OnRemovingTag installs the hook run before a disallowed tag is removed.
// Return true from fn to CANCEL the removal.
func (s *Sanitizer) OnRemovingTag(fn RemovingTagFunc) *Sanitizer {
	s.onRemovingTag = fn
	if fn == nil {
		C.aether_hs_embed_on_removing_tag(s.h, nil, nil)
		return s
	}
	C.aether_hs_embed_on_removing_tag(s.h, unsafe.Pointer(C.hsgo_removing_tag), s.ud())
	return s
}

// OnRemovingAttribute installs the hook run before a disallowed attribute is
// removed. Return true from fn to CANCEL the removal.
func (s *Sanitizer) OnRemovingAttribute(fn RemovingAttributeFunc) *Sanitizer {
	s.onRemovingAttribute = fn
	if fn == nil {
		C.aether_hs_embed_on_removing_attribute(s.h, nil, nil)
		return s
	}
	C.aether_hs_embed_on_removing_attribute(s.h, unsafe.Pointer(C.hsgo_removing_attribute), s.ud())
	return s
}

// OnRemovingStyle installs the hook run before a disallowed CSS property is
// removed. Return true from fn to CANCEL the removal.
func (s *Sanitizer) OnRemovingStyle(fn RemovingStyleFunc) *Sanitizer {
	s.onRemovingStyle = fn
	if fn == nil {
		C.aether_hs_embed_on_removing_style(s.h, nil, nil)
		return s
	}
	C.aether_hs_embed_on_removing_style(s.h, unsafe.Pointer(C.hsgo_removing_style), s.ud())
	return s
}

// OnRemovingComment installs the hook run before a comment is removed. Return
// true from fn to CANCEL the removal.
func (s *Sanitizer) OnRemovingComment(fn RemovingCommentFunc) *Sanitizer {
	s.onRemovingComment = fn
	if fn == nil {
		C.aether_hs_embed_on_removing_comment(s.h, nil, nil)
		return s
	}
	C.aether_hs_embed_on_removing_comment(s.h, unsafe.Pointer(C.hsgo_removing_comment), s.ud())
	return s
}

// OnPostProcessNode installs a per-node observer run after filtering.
func (s *Sanitizer) OnPostProcessNode(fn PostProcessFunc) *Sanitizer {
	s.onPostProcessNode = fn
	if fn == nil {
		C.aether_hs_embed_on_post_process_node(s.h, nil, nil)
		return s
	}
	C.aether_hs_embed_on_post_process_node(s.h, unsafe.Pointer(C.hsgo_post_process_node), s.ud())
	return s
}

// OnPostProcessDOM installs a whole-document observer run after filtering.
func (s *Sanitizer) OnPostProcessDOM(fn PostProcessFunc) *Sanitizer {
	s.onPostProcessDOM = fn
	if fn == nil {
		C.aether_hs_embed_on_post_process_dom(s.h, nil, nil)
		return s
	}
	C.aether_hs_embed_on_post_process_dom(s.h, unsafe.Pointer(C.hsgo_post_process_dom), s.ud())
	return s
}

// OnFilterURL installs the URL-rewriting hook. fn returns the URL to use:
// resolved unchanged for "no rewrite", or "" to drop the attribute. The
// returned string is copied into a C buffer the sanitizer core takes ownership of.
func (s *Sanitizer) OnFilterURL(fn FilterURLFunc) *Sanitizer {
	s.onFilterURL = fn
	if fn == nil {
		C.aether_hs_embed_on_filter_url(s.h, nil, nil)
		return s
	}
	C.aether_hs_embed_on_filter_url(s.h, unsafe.Pointer(C.hsgo_filter_url), s.ud())
	return s
}

// ---- package-level conveniences ----

// Sanitize cleans a fragment with the sanitizer core's secure defaults, creating and
// releasing a sanitizer around the call.
func Sanitize(html, baseURL string) (string, error) {
	s, err := New()
	if err != nil {
		return "", err
	}
	defer s.Close()
	return s.SanitizeErr(html, baseURL)
}

// SanitizeDocument cleans a whole document with the sanitizer core's secure defaults.
func SanitizeDocument(html, baseURL string) (string, error) {
	s, err := New()
	if err != nil {
		return "", err
	}
	defer s.Close()
	return s.SanitizeDocumentErr(html, baseURL)
}
