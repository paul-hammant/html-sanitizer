package htmlsanitizer

/*
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import (
	"runtime/cgo"
	"unsafe"
)

// The //export-ed functions below ARE the C trampolines named in bridge.h.
// cgo emits a real C symbol for each, so `&C.hsgo_removing_tag` in
// htmlsanitizer.go is a genuine function pointer the engine can call.
//
// Every one receives the ABI's opaque user_data first. What we put there is a
// malloc'd cell holding a runtime/cgo.Handle token — never a Go pointer, which
// is what makes this legal under the cgo pointer-passing rules, and never a
// bare integer cast to unsafe.Pointer, which -race/checkptr rejects. The token
// resolves back to the owning *Sanitizer, whose registered Go closure we then
// invoke.
//
// A callback must never let a Go panic unwind into C. Each trampoline is a
// thin adapter over a user closure; a panic in that closure is the user's, and
// would abort the process from the C stack, so keep hooks total.

func ownerOf(ud unsafe.Pointer) *Sanitizer {
	if ud == nil {
		return nil
	}
	v := cgo.Handle(*(*C.uintptr_t)(ud)).Value()
	s, _ := v.(*Sanitizer)
	return s
}

//export hsgo_removing_tag
func hsgo_removing_tag(ud unsafe.Pointer, node unsafe.Pointer, reason C.int) C.int {
	s := ownerOf(ud)
	if s == nil || s.onRemovingTag == nil {
		return 0
	}
	return cbool(s.onRemovingTag(Node{lib: s.lib, ptr: node}, Reason(reason)))
}

//export hsgo_removing_attribute
func hsgo_removing_attribute(ud, elem, attr unsafe.Pointer, reason C.int) C.int {
	s := ownerOf(ud)
	if s == nil || s.onRemovingAttribute == nil {
		return 0
	}
	return cbool(s.onRemovingAttribute(
		Node{lib: s.lib, ptr: elem},
		Attribute{lib: s.lib, ptr: attr},
		Reason(reason)))
}

//export hsgo_removing_style
func hsgo_removing_style(ud, elem unsafe.Pointer, name, value *C.char, reason C.int) C.int {
	s := ownerOf(ud)
	if s == nil || s.onRemovingStyle == nil {
		return 0
	}
	return cbool(s.onRemovingStyle(
		Node{lib: s.lib, ptr: elem},
		goStr(name), goStr(value), Reason(reason)))
}

//export hsgo_removing_comment
func hsgo_removing_comment(ud, node unsafe.Pointer) C.int {
	s := ownerOf(ud)
	if s == nil || s.onRemovingComment == nil {
		return 0
	}
	return cbool(s.onRemovingComment(Node{lib: s.lib, ptr: node}))
}

//export hsgo_post_process_node
func hsgo_post_process_node(ud, node unsafe.Pointer) {
	s := ownerOf(ud)
	if s == nil || s.onPostProcessNode == nil {
		return
	}
	s.onPostProcessNode(Node{lib: s.lib, ptr: node})
}

//export hsgo_post_process_dom
func hsgo_post_process_dom(ud, node unsafe.Pointer) {
	s := ownerOf(ud)
	if s == nil || s.onPostProcessDOM == nil {
		return
	}
	s.onPostProcessDOM(Node{lib: s.lib, ptr: node})
}

//export hsgo_filter_url
func hsgo_filter_url(ud, elem unsafe.Pointer, raw, resolved *C.char) *C.char {
	s := ownerOf(ud)
	if s == nil || s.onFilterURL == nil {
		// No hook: hand the resolved pointer straight back — the ABI's
		// documented "no rewrite" answer.
		return resolved
	}
	out := s.onFilterURL(Node{lib: s.lib, ptr: elem}, goStr(raw), goStr(resolved))
	// The engine takes ownership of what we return, so it must be a malloc'd
	// C buffer: C.CString allocates with malloc, which is exactly right.
	return C.CString(out)
}

// cbool maps the Go "cancel the removal?" answer onto the ABI's convention:
// NON-ZERO cancels, zero proceeds.
func cbool(b bool) C.int {
	if b {
		return 1
	}
	return 0
}

// goStr copies a borrowed const char* callback argument into a Go string.
// It does NOT free — these arguments are owned by the engine.
func goStr(s *C.char) string {
	if s == nil {
		return ""
	}
	return C.GoString(s)
}
