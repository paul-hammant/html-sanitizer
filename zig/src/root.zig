//! htmlsanitizer — the Zig binding over the monorepo's one shared native engine.
//!
//! Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).
//!
//! There is **no sanitizer logic in this file**. Parsing, filtering, URL
//! resolution and CSS handling all live in `core/htmlsanitizer.ae` (pure
//! Aether), exposed over the flat C ABI declared in `core/embed.ae`. This
//! module marshals values across that boundary and nothing else. If a
//! behaviour looks wrong, the bug is in the engine or in this marshalling —
//! it is never a policy decision made here.
//!
//! ## Which family of binding is this?
//!
//! Like Go's cgo binding (and unlike Python/ctypes or Ruby/Fiddle), this one
//! **links** the engine rather than `dlopen`ing it: the `extern "c"`
//! declarations below resolve at link time against `-lhtmlsanitizer`. That
//! means the `.so` must exist when you *build*, not only when you run.
//! `build.zig` handles the `-L` and the `rpath`; see the README.
//!
//! Linking (rather than dlopen) is the right trade for Zig specifically:
//! Zig has no runtime, so there is no GC to fight and no FFI marshalling
//! layer to pay for — a `callconv(.c)` function *is* a C function pointer,
//! and a `*anyopaque` into a Zig struct *is* a `void*`. The whole binding is
//! therefore zero-overhead: it compiles to the same calls a hand-written C
//! consumer would make.
//!
//! ## The three rules that matter
//!
//! **1. Every `[*c]u8` this ABI returns is CALLER-OWNED.** It came from
//! `hs_raw_dup` (a plain `malloc`) inside the engine, and must go back
//! through `aether_hs_embed_free_string`. Forgetting this is the single most
//! common bug in a binding, so this file routes *every* returned string
//! through exactly one helper, `takeString`, which copies into a caller
//! supplied allocator and frees the C buffer in a `defer` on the same line it
//! acquired it. There is no second path. Grep for `free_string` — it appears
//! once.
//!
//! **2. Callback integer arguments are C `int`, NOT `long`.** The engine's
//! codegen emits its closure calls as `int (*)(...)`, so a host declaring
//! `c_long` gets a 4-vs-8-byte mismatch on LP64: garbage `reason` values and,
//! worse, corrupted stack arguments after it. Every callback below uses
//! `c_int`. Zig will not warn you about this — the ABI is whatever you
//! declare — so it is asserted by the conformance tests, which check the
//! `reason` value they receive rather than merely ignoring it.
//!
//! **3. A registered callback must outlive the engine's ability to call it.**
//! The engine stores the raw function pointer and the raw `user_data` in a
//! malloc'd box and calls them from inside `sanitize`. Zig's
//! `callconv(.c)` functions are static code — they cannot move or be
//! collected — so the *function* half is free. The `user_data` half is not:
//! it points at a `Sanitizer`'s `hooks` field, so the `Sanitizer` must not
//! move or die while a hook is registered. That is why `Sanitizer` is heap
//! allocated by `init` and handed back as a `*Sanitizer` rather than returned
//! by value: a by-value return would let the caller stack-copy it, leaving
//! the engine holding a pointer to a dead stack frame. See `Hooks`.
//!
//! ## Borrowed vs owned pointers
//!
//! The node/attribute pointers a callback receives are **borrowed** — valid
//! only for the duration of that callback, because the DOM is freed when
//! `sanitize` returns. `Node` and `Attribute` are therefore thin non-owning
//! wrappers with no `deinit`. Retaining one past the callback is a
//! use-after-free the type system cannot catch for you.

const std = @import("std");

// =========================================================================
// The C ABI — a 1:1 transcription of core/embed.ae.
//
// `core/embed.ae` names its exports `hs_embed_<name>`; building with
// `--emit=lib` mangles them to `aether_hs_embed_<name>`, which is what we
// link against. Declaration order mirrors embed.ae so the two can be diffed
// by eye — the canonical cross-binding reference is rust/src/native.rs.
//
// Types: `?*anyopaque` for every opaque handle/node/attr (nullable because
// the ABI is documented NULL-safe in both directions), `[*c]const u8` for
// strings we hand in (C-pointer syntax so a Zig string literal's
// sentinel-terminated type coerces automatically), and `[*c]u8` for strings
// the ABI hands back — the pointer-ness is a reminder that we now own it.
// =========================================================================

const c = struct {
    // ---- lifecycle ----
    extern "c" fn aether_hs_embed_new() ?*anyopaque;
    extern "c" fn aether_hs_embed_free(h: ?*anyopaque) void;
    extern "c" fn aether_hs_embed_free_string(s: [*c]u8) void;

    // ---- the main entry points ----
    extern "c" fn aether_hs_embed_sanitize(h: ?*anyopaque, html: [*c]const u8, base_url: [*c]const u8) [*c]u8;
    extern "c" fn aether_hs_embed_sanitize_document(h: ?*anyopaque, html: [*c]const u8, base_url: [*c]const u8) [*c]u8;

    // ---- boolean flags (marshalled as int, because C has no bool here) ----
    extern "c" fn aether_hs_embed_set_keep_child_nodes(h: ?*anyopaque, on: c_int) void;
    extern "c" fn aether_hs_embed_get_keep_child_nodes(h: ?*anyopaque) c_int;
    extern "c" fn aether_hs_embed_set_allow_data_attributes(h: ?*anyopaque, on: c_int) void;
    extern "c" fn aether_hs_embed_get_allow_data_attributes(h: ?*anyopaque) c_int;

    // ---- allow-list mutation (the `which` selector is an ABI constant) ----
    extern "c" fn aether_hs_embed_allow(h: ?*anyopaque, which: c_int, item: [*c]const u8) c_int;
    extern "c" fn aether_hs_embed_disallow(h: ?*anyopaque, which: c_int, item: [*c]const u8) c_int;
    extern "c" fn aether_hs_embed_is_allowed(h: ?*anyopaque, which: c_int, item: [*c]const u8) c_int;
    extern "c" fn aether_hs_embed_clear(h: ?*anyopaque, which: c_int) c_int;
    extern "c" fn aether_hs_embed_count(h: ?*anyopaque, which: c_int) c_int;
    extern "c" fn aether_hs_embed_item_at(h: ?*anyopaque, which: c_int, index: c_int) [*c]u8;

    // ---- callbacks (fn pointer + opaque user_data; a null fn clears) ----
    extern "c" fn aether_hs_embed_on_removing_tag(h: ?*anyopaque, fn_ptr: ?*const anyopaque, ud: ?*anyopaque) void;
    extern "c" fn aether_hs_embed_on_removing_attribute(h: ?*anyopaque, fn_ptr: ?*const anyopaque, ud: ?*anyopaque) void;
    extern "c" fn aether_hs_embed_on_removing_style(h: ?*anyopaque, fn_ptr: ?*const anyopaque, ud: ?*anyopaque) void;
    extern "c" fn aether_hs_embed_on_removing_comment(h: ?*anyopaque, fn_ptr: ?*const anyopaque, ud: ?*anyopaque) void;
    extern "c" fn aether_hs_embed_on_post_process_node(h: ?*anyopaque, fn_ptr: ?*const anyopaque, ud: ?*anyopaque) void;
    extern "c" fn aether_hs_embed_on_post_process_dom(h: ?*anyopaque, fn_ptr: ?*const anyopaque, ud: ?*anyopaque) void;
    extern "c" fn aether_hs_embed_on_filter_url(h: ?*anyopaque, fn_ptr: ?*const anyopaque, ud: ?*anyopaque) void;

    // ---- DOM accessors (borrowed pointers, valid only inside a callback) ----
    extern "c" fn aether_hs_embed_node_kind(n: ?*anyopaque) c_int;
    extern "c" fn aether_hs_embed_node_name(n: ?*anyopaque) [*c]u8;
    extern "c" fn aether_hs_embed_node_value(n: ?*anyopaque) [*c]u8;
    extern "c" fn aether_hs_embed_node_child_count(n: ?*anyopaque) c_int;
    extern "c" fn aether_hs_embed_node_child_at(n: ?*anyopaque, index: c_int) ?*anyopaque;
    extern "c" fn aether_hs_embed_node_parent(n: ?*anyopaque) ?*anyopaque;
    extern "c" fn aether_hs_embed_node_attr_count(n: ?*anyopaque) c_int;
    extern "c" fn aether_hs_embed_node_attr_at(n: ?*anyopaque, index: c_int) ?*anyopaque;
    extern "c" fn aether_hs_embed_attr_name(a: ?*anyopaque) [*c]u8;
    extern "c" fn aether_hs_embed_attr_value(a: ?*anyopaque) [*c]u8;
    extern "c" fn aether_hs_embed_attr_set_value(a: ?*anyopaque, value: [*c]const u8) void;

    // ---- version / introspection ----
    extern "c" fn aether_hs_embed_abi_version() c_int;

    // ---- the engine's own strdup ----
    //
    // Not an `aether_hs_embed_*` export — it is the raw C helper in
    // core/_embed_support.c, exported unmangled because it is plain C. It is
    // the clean way to produce `filterUrl`'s return value: the engine frees
    // that buffer with `free()`, so it must come from the *same* libc
    // `malloc`. Calling this rather than declaring `malloc` ourselves means
    // the allocation and the free provably come from one allocator, even in
    // a build where the engine and the host link different libc runtimes.
    extern "c" fn hs_raw_dup(s: [*c]const u8) [*c]u8;
};

// =========================================================================
// ABI constants — append only, never renumber.
// =========================================================================

/// Which of the six parallel allow-lists a mutation applies to.
///
/// The ABI takes an int selector rather than exposing six near-identical
/// export families; we give it a name so callers never write a bare `3`.
pub const ListKind = enum(c_int) {
    tags = 0,
    attributes = 1,
    css_properties = 2,
    schemes = 3,
    classes = 4,
    uri_attributes = 5,
};

/// Why the engine is about to remove something, as handed to a `removing_*`
/// hook. Non-exhaustive: the ABI is append-only, so a future engine may pass
/// a reason this build has no name for, and that must not be illegal-value
/// UB in a Zig enum.
pub const Reason = enum(c_int) {
    not_allowed_tag = 0,
    not_allowed_attribute = 1,
    not_allowed_style = 2,
    not_allowed_url_value = 3,
    not_allowed_value = 4,
    not_allowed_css_class = 5,
    class_attribute_empty = 6,
    style_attribute_empty = 7,
    _,
};

/// DOM node kinds. Also non-exhaustive, for the same append-only reason.
pub const NodeKind = enum(c_int) {
    /// A null node pointer reports 0.
    none = 0,
    document = 1,
    element = 2,
    text = 3,
    comment = 4,
    _,
};

pub const Error = error{
    /// The engine refused to allocate a sanitizer (`hs_embed_new` returned null).
    AllocFailed,
    /// A Zig string contained an interior NUL and cannot cross a C `char*`.
    /// Truncating silently would be a security bug in a *sanitizer* binding:
    /// the engine would see less HTML than the caller believes it sanitized.
    InteriorNul,
    /// Out of memory copying an ABI string into Zig-owned storage.
    OutOfMemory,
};

/// The ABI revision this engine implements. Check it to fail fast against an
/// engine older than the features you expect.
pub fn abiVersion() i32 {
    return @intCast(c.aether_hs_embed_abi_version());
}

// =========================================================================
// String marshalling — the ONE place returned strings are freed.
// =========================================================================

/// Copy an ABI-returned string into `allocator` and free the C buffer.
///
/// RULE 1 lives here and nowhere else. Every function in this file that
/// receives a `[*c]u8` from the ABI hands it straight to this, so there is
/// exactly one `free_string` call site to audit. The `defer` is on the line
/// after acquisition so no early return can skip it.
///
/// A null return is treated as `""`. The ABI documents that it never returns
/// null (it dups `""` instead), but a null-deref in a sanitizer is a worse
/// failure mode than an empty string.
fn takeString(allocator: std.mem.Allocator, ptr: [*c]u8) Error![]u8 {
    if (ptr == null) return allocator.dupe(u8, "") catch return Error.OutOfMemory;
    defer c.aether_hs_embed_free_string(ptr);
    const slice = std.mem.span(@as([*:0]u8, @ptrCast(ptr)));
    return allocator.dupe(u8, slice) catch Error.OutOfMemory;
}

/// Read a **borrowed** `const char*` a callback was handed. We do NOT own it
/// and must not free it; the returned slice is only valid for the duration of
/// the callback. Distinct from `takeString` on purpose — conflating the two
/// is how a binding acquires a double-free.
fn borrowString(ptr: [*c]const u8) []const u8 {
    if (ptr == null) return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
}

/// Stack-buffer helper for handing a Zig slice to a C `const char*`.
///
/// Most values crossing this ABI are short — a tag name, a scheme, an
/// attribute value — so we NUL-terminate in a fixed buffer and avoid an
/// allocation. Anything longer falls back to the allocator. `sanitize` uses
/// the allocator path directly since HTML is arbitrarily long.
const StackCStr = struct {
    buf: [256]u8 = undefined,
    heap: ?[]u8 = null,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, s: []const u8) Error!StackCStr {
        // An interior NUL would silently truncate the string at the C
        // boundary. For a sanitizer that is not a cosmetic bug: the caller
        // would believe it sanitized more than the engine ever saw.
        if (std.mem.indexOfScalar(u8, s, 0) != null) return Error.InteriorNul;
        var self = StackCStr{ .allocator = allocator };
        if (s.len + 1 <= self.buf.len) {
            @memcpy(self.buf[0..s.len], s);
            self.buf[s.len] = 0;
        } else {
            const h = allocator.alloc(u8, s.len + 1) catch return Error.OutOfMemory;
            @memcpy(h[0..s.len], s);
            h[s.len] = 0;
            self.heap = h;
        }
        return self;
    }

    fn ptr(self: *const StackCStr) [*c]const u8 {
        if (self.heap) |h| return h.ptr;
        return &self.buf;
    }

    fn deinit(self: *StackCStr) void {
        if (self.heap) |h| self.allocator.free(h);
        self.heap = null;
    }
};

// =========================================================================
// Borrowed DOM views
// =========================================================================

/// A borrowed DOM node, valid only inside the callback that received it.
///
/// Non-owning: there is no `deinit`, because the engine frees the whole DOM
/// when `sanitize` returns. Retaining a `Node` past the callback is a
/// use-after-free. The accessors that return strings need an allocator
/// because the ABI hands back owned copies (rule 1) which we must re-own.
pub const Node = struct {
    ptr: ?*anyopaque,

    pub fn kind(self: Node) NodeKind {
        return @enumFromInt(c.aether_hs_embed_node_kind(self.ptr));
    }

    /// Lowercased tag name; `""` for non-elements. Caller frees.
    pub fn name(self: Node, allocator: std.mem.Allocator) Error![]u8 {
        return takeString(allocator, c.aether_hs_embed_node_name(self.ptr));
    }

    /// Text/comment content; `""` for elements and documents. Caller frees.
    pub fn value(self: Node, allocator: std.mem.Allocator) Error![]u8 {
        return takeString(allocator, c.aether_hs_embed_node_value(self.ptr));
    }

    pub fn childCount(self: Node) usize {
        const n = c.aether_hs_embed_node_child_count(self.ptr);
        return if (n < 0) 0 else @intCast(n);
    }

    pub fn childAt(self: Node, index: usize) ?Node {
        const p = c.aether_hs_embed_node_child_at(self.ptr, @intCast(index));
        return if (p == null) null else Node{ .ptr = p };
    }

    pub fn parent(self: Node) ?Node {
        const p = c.aether_hs_embed_node_parent(self.ptr);
        return if (p == null) null else Node{ .ptr = p };
    }

    pub fn attrCount(self: Node) usize {
        const n = c.aether_hs_embed_node_attr_count(self.ptr);
        return if (n < 0) 0 else @intCast(n);
    }

    pub fn attrAt(self: Node, index: usize) ?Attribute {
        const p = c.aether_hs_embed_node_attr_at(self.ptr, @intCast(index));
        return if (p == null) null else Attribute{ .ptr = p };
    }
};

/// A borrowed DOM attribute. Same lifetime rules as `Node`.
pub const Attribute = struct {
    ptr: ?*anyopaque,

    /// Caller frees.
    pub fn name(self: Attribute, allocator: std.mem.Allocator) Error![]u8 {
        return takeString(allocator, c.aether_hs_embed_attr_name(self.ptr));
    }

    /// Caller frees.
    pub fn value(self: Attribute, allocator: std.mem.Allocator) Error![]u8 {
        return takeString(allocator, c.aether_hs_embed_attr_value(self.ptr));
    }

    /// Rewrite the attribute in place — e.g. canonicalise a URL rather than
    /// remove the attribute.
    ///
    /// Safe to pass a transient buffer: `hs_embed_attr_set_value` COPIES
    /// engine-side (`string.concat("", value)`), so nothing aliases our
    /// stack after this returns. That is a documented ABI guarantee, not an
    /// implementation detail we are relying on by accident.
    pub fn setValue(self: Attribute, allocator: std.mem.Allocator, v: []const u8) Error!void {
        var cs = try StackCStr.init(allocator, v);
        defer cs.deinit();
        c.aether_hs_embed_attr_set_value(self.ptr, cs.ptr());
    }
};

// =========================================================================
// Hooks
// =========================================================================

/// The seven host callbacks, in Zig terms.
///
/// Each is an optional `*const fn` taking a `?*anyopaque` context the caller
/// chooses — the same "closure by explicit environment" shape the C ABI uses,
/// which is also the only shape Zig offers without allocating a closure.
///
/// For the `removing_*` family, **returning `true` CANCELS the removal**
/// (i.e. keeps the node/attribute/property). This inverts the naive reading
/// of the callback name, and matches the C ABI's "non-zero cancels".
pub const Hooks = struct {
    /// User context passed to every hook below. Not touched by this module.
    ctx: ?*anyopaque = null,

    /// Return true to KEEP the tag.
    removing_tag: ?*const fn (ctx: ?*anyopaque, node: Node, reason: Reason) bool = null,
    /// Return true to KEEP the attribute.
    removing_attribute: ?*const fn (ctx: ?*anyopaque, elem: Node, attr: Attribute, reason: Reason) bool = null,
    /// Four arguments plus ctx, unlike the tag/attribute hooks. `name` and
    /// `value` are BORROWED for the call only. Return true to KEEP.
    removing_style: ?*const fn (ctx: ?*anyopaque, elem: Node, name: []const u8, value: []const u8, reason: Reason) bool = null,
    /// Return true to KEEP the comment.
    removing_comment: ?*const fn (ctx: ?*anyopaque, node: Node) bool = null,
    post_process_node: ?*const fn (ctx: ?*anyopaque, node: Node) void = null,
    post_process_dom: ?*const fn (ctx: ?*anyopaque, doc: Node) void = null,
    /// The hardest shape: return the URL to use. `raw` and `resolved` are
    /// BORROWED. Return `resolved` unchanged for "no rewrite", `""` to drop
    /// the attribute, or any other slice to substitute it — the binding
    /// copies it into an engine-owned buffer for you (see `trampFilterUrl`),
    /// so you never allocate for the return value and never free it.
    filter_url: ?*const fn (ctx: ?*anyopaque, elem: Node, raw: []const u8, resolved: []const u8) []const u8 = null,
};

/// A bool per hook slot, field-for-field with `Hooks`. `setHooks` compares the
/// two to decide which registration calls are actually needed.
const RegisteredSlots = struct {
    removing_tag: bool = false,
    removing_attribute: bool = false,
    removing_style: bool = false,
    removing_comment: bool = false,
    post_process_node: bool = false,
    post_process_dom: bool = false,
    filter_url: bool = false,
};

// ---- the trampolines ----
//
// These are the actual C function pointers the engine stores. Each has the
// exact C signature from core/embed.ae, with `user_data` FIRST and every
// integer a `c_int` — see rule 2 in the module doc. They unpack `ud` back
// into the owning `*Sanitizer` and dispatch to the Zig-level `Hooks`.
//
// `callconv(.c)` is what makes these usable as C function pointers at all.
// They are static code, so unlike a Go closure or a Python bound method they
// need no keepalive of their own; only the `ud` pointer does.
//
// A null hook returning 0 is the safe default: 0 means "proceed with the
// removal", which is the conservative choice for a sanitizer. A hook that
// disappeared must never accidentally start *keeping* dangerous markup.

fn selfFrom(ud: ?*anyopaque) ?*Sanitizer {
    if (ud == null) return null;
    return @ptrCast(@alignCast(ud.?));
}

fn trampRemovingTag(ud: ?*anyopaque, node: ?*anyopaque, reason: c_int) callconv(.c) c_int {
    const self = selfFrom(ud) orelse return 0;
    const f = self.hooks.removing_tag orelse return 0;
    return if (f(self.hooks.ctx, Node{ .ptr = node }, @enumFromInt(reason))) 1 else 0;
}

fn trampRemovingAttribute(ud: ?*anyopaque, elem: ?*anyopaque, attr: ?*anyopaque, reason: c_int) callconv(.c) c_int {
    const self = selfFrom(ud) orelse return 0;
    const f = self.hooks.removing_attribute orelse return 0;
    return if (f(self.hooks.ctx, Node{ .ptr = elem }, Attribute{ .ptr = attr }, @enumFromInt(reason))) 1 else 0;
}

fn trampRemovingStyle(
    ud: ?*anyopaque,
    elem: ?*anyopaque,
    name: [*c]const u8,
    value: [*c]const u8,
    reason: c_int,
) callconv(.c) c_int {
    const self = selfFrom(ud) orelse return 0;
    const f = self.hooks.removing_style orelse return 0;
    // Borrowed for the duration of this call only — the C trampoline in
    // _embed_support.c unwrapped them out of the engine's AetherString, and
    // they die with the DOM.
    return if (f(self.hooks.ctx, Node{ .ptr = elem }, borrowString(name), borrowString(value), @enumFromInt(reason))) 1 else 0;
}

fn trampRemovingComment(ud: ?*anyopaque, node: ?*anyopaque) callconv(.c) c_int {
    const self = selfFrom(ud) orelse return 0;
    const f = self.hooks.removing_comment orelse return 0;
    return if (f(self.hooks.ctx, Node{ .ptr = node })) 1 else 0;
}

fn trampPostProcessNode(ud: ?*anyopaque, node: ?*anyopaque) callconv(.c) void {
    const self = selfFrom(ud) orelse return;
    const f = self.hooks.post_process_node orelse return;
    f(self.hooks.ctx, Node{ .ptr = node });
}

fn trampPostProcessDom(ud: ?*anyopaque, node: ?*anyopaque) callconv(.c) void {
    const self = selfFrom(ud) orelse return;
    const f = self.hooks.post_process_dom orelse return;
    f(self.hooks.ctx, Node{ .ptr = node });
}

/// The string-returning hook — the one shape a binding is most likely to get
/// subtly wrong.
///
/// Ownership, precisely:
///   * `raw` / `resolved` in are BORROWED. Do not free them, do not retain
///     them.
///   * The `char*` we return is TAKEN by the engine, which copies it into an
///     Aether string and then `free()`s our buffer. So it must be a plain
///     libc-`malloc`'d block — a Zig-allocator block would be freed by the
///     wrong allocator, which is heap corruption, not a leak.
///   * Returning the `resolved` pointer UNCHANGED is the documented "no
///     rewrite" signal, and the C side special-cases pointer equality to
///     avoid a needless copy. We take that fast path whenever the hook hands
///     back a slice that aliases `resolved`.
///
/// We produce the malloc'd copy with the engine's own `hs_raw_dup` rather
/// than declaring `malloc` ourselves. Same allocator as the engine's `free`,
/// by construction.
fn trampFilterUrl(
    ud: ?*anyopaque,
    elem: ?*anyopaque,
    raw: [*c]const u8,
    resolved: [*c]const u8,
) callconv(.c) [*c]u8 {
    // No hook (or no self): "no rewrite" is returning `resolved` unchanged.
    const self = selfFrom(ud) orelse return @constCast(resolved);
    const f = self.hooks.filter_url orelse return @constCast(resolved);

    const raw_slice = borrowString(raw);
    const resolved_slice = borrowString(resolved);
    const out = f(self.hooks.ctx, Node{ .ptr = elem }, raw_slice, resolved_slice);

    // Fast path: the hook returned the very slice we gave it. Hand the
    // original pointer straight back — no allocation, and the C trampoline
    // recognises the pointer identity as "no rewrite".
    if (out.ptr == resolved_slice.ptr and out.len == resolved_slice.len) {
        return @constCast(resolved);
    }

    // Otherwise copy into an engine-allocated buffer. `hs_raw_dup` takes a
    // NUL-terminated string, so we need one; a stack buffer covers every
    // realistic URL, and anything longer is worth an allocation. On failure
    // there is no way to report an error to the engine mid-sanitize, so we
    // degrade to "no rewrite" rather than returning null (which the C side
    // would also treat as no-rewrite, but via a less obvious path).
    var stack: [2048]u8 = undefined;
    if (out.len + 1 <= stack.len) {
        @memcpy(stack[0..out.len], out);
        stack[out.len] = 0;
        return c.hs_raw_dup(&stack);
    }
    const heap = std.heap.c_allocator.allocSentinel(u8, out.len, 0) catch return @constCast(resolved);
    defer std.heap.c_allocator.free(heap);
    @memcpy(heap[0..out.len], out);
    return c.hs_raw_dup(heap.ptr);
}

// =========================================================================
// Sanitizer
// =========================================================================

/// One configured sanitizer. Wraps the engine's opaque handle.
///
/// **Heap-allocated on purpose.** `init` returns a `*Sanitizer` rather than a
/// `Sanitizer` because the address of this struct is what we hand the engine
/// as every hook's `user_data` (rule 3). A by-value return would let the
/// caller copy it to a different address, and the engine would then call back
/// into whatever used to be there.
///
/// **Not safe for concurrent use** — the native handle carries mutable policy
/// and hook state. Use one per thread, or guard it.
pub const Sanitizer = struct {
    handle: ?*anyopaque,
    allocator: std.mem.Allocator,
    /// The registered hooks. The engine holds `&self` as `user_data` for each
    /// registered slot, and reads this field from inside `sanitize`. It must
    /// stay put and stay valid for as long as any hook is registered — which
    /// is guaranteed by `Sanitizer` being heap-allocated and by `deinit`
    /// clearing every hook before freeing the handle.
    hooks: Hooks = .{},

    /// Which slots are currently registered ENGINE-side. Mirrors `hooks`, but
    /// tracks the engine's view rather than ours so `setHooks` can touch the
    /// ABI only on an actual transition — see the note there about the
    /// engine's replace-path box leak.
    registered: RegisteredSlots = .{},

    /// Create a sanitizer with the engine's secure defaults populated
    /// (allowed tags, attributes, CSS properties, schemes, URI attributes).
    pub fn init(allocator: std.mem.Allocator) Error!*Sanitizer {
        const h = c.aether_hs_embed_new() orelse return Error.AllocFailed;
        const self = allocator.create(Sanitizer) catch {
            // Do not leak the native handle just because the Zig-side
            // allocation failed.
            c.aether_hs_embed_free(h);
            return Error.OutOfMemory;
        };
        self.* = .{ .handle = h, .allocator = allocator };
        return self;
    }

    /// Release the native handle and the wrapper. Idempotent in the sense
    /// that the handle is nulled first, but the `*Sanitizer` itself is freed
    /// here — do not call twice.
    pub fn deinit(self: *Sanitizer) void {
        if (self.handle) |h| {
            // Do NOT clear the hooks first.
            //
            // That is the obvious defensive move, and it is wrong here. The
            // engine's `hs_embed_free` already unregisters and frees each
            // installed hook box correctly — but clearing a hook *manually*
            // goes through `swap_hook`, whose replace path never frees the
            // outgoing box (see the note on `setHooks`). So a tidy-looking
            // clear-then-free leaks exactly one 16-byte box per hook, while
            // simply freeing the handle leaks nothing. Verified in pure C
            // against the engine, with no binding involved.
            //
            // There is no lifetime risk in leaving them installed: the engine
            // cannot call a hook after `hs_embed_free` returns, and we destroy
            // `self` only after that.
            c.aether_hs_embed_free(h);
            self.handle = null;
            self.hooks = .{};
            self.registered = .{};
        }
        self.allocator.destroy(self);
    }

    /// Clear every slot. Routed through `setHooks` so it takes the same
    /// change-tracking path — clearing an already-clear slot would otherwise
    /// hit the engine's leaky replace path for no reason.
    fn clearHooks(self: *Sanitizer) void {
        self.setHooks(.{});
    }

    // ---- the main entry points ----

    /// Sanitize an HTML fragment. `base_url` may be `""` (no resolution of
    /// relative URLs). **The caller owns the returned slice** and frees it
    /// with the same allocator.
    pub fn sanitize(self: *Sanitizer, html: []const u8, base_url: []const u8) Error![]u8 {
        return self.call(c.aether_hs_embed_sanitize, html, base_url);
    }

    /// Sanitize a full HTML document. Currently the same engine path as
    /// `sanitize`; kept distinct so the two-method surface does not drift.
    pub fn sanitizeDocument(self: *Sanitizer, html: []const u8, base_url: []const u8) Error![]u8 {
        return self.call(c.aether_hs_embed_sanitize_document, html, base_url);
    }

    fn call(
        self: *Sanitizer,
        f: *const fn (?*anyopaque, [*c]const u8, [*c]const u8) callconv(.c) [*c]u8,
        html: []const u8,
        base_url: []const u8,
    ) Error![]u8 {
        // HTML is arbitrarily long, so NUL-terminate through the allocator
        // rather than a stack buffer.
        if (std.mem.indexOfScalar(u8, html, 0) != null) return Error.InteriorNul;
        const chtml = self.allocator.dupeZ(u8, html) catch return Error.OutOfMemory;
        defer self.allocator.free(chtml);
        var cbase = try StackCStr.init(self.allocator, base_url);
        defer cbase.deinit();
        return takeString(self.allocator, f(self.handle, chtml.ptr, cbase.ptr()));
    }

    // ---- boolean flags (int over the wire — check 9) ----

    pub fn setKeepChildNodes(self: *Sanitizer, on: bool) void {
        c.aether_hs_embed_set_keep_child_nodes(self.handle, @intFromBool(on));
    }

    pub fn getKeepChildNodes(self: *Sanitizer) bool {
        return c.aether_hs_embed_get_keep_child_nodes(self.handle) != 0;
    }

    pub fn setAllowDataAttributes(self: *Sanitizer, on: bool) void {
        c.aether_hs_embed_set_allow_data_attributes(self.handle, @intFromBool(on));
    }

    pub fn getAllowDataAttributes(self: *Sanitizer) bool {
        return c.aether_hs_embed_get_allow_data_attributes(self.handle) != 0;
    }

    // ---- allow-list mutation ----

    /// Add `item` to one of the six lists. Returns false on a bad handle.
    pub fn allow(self: *Sanitizer, which: ListKind, item: []const u8) Error!bool {
        var cs = try StackCStr.init(self.allocator, item);
        defer cs.deinit();
        return c.aether_hs_embed_allow(self.handle, @intFromEnum(which), cs.ptr()) != 0;
    }

    /// Remove `item` — the "deny" direction (e.g. drop `div` from tags).
    pub fn disallow(self: *Sanitizer, which: ListKind, item: []const u8) Error!bool {
        var cs = try StackCStr.init(self.allocator, item);
        defer cs.deinit();
        return c.aether_hs_embed_disallow(self.handle, @intFromEnum(which), cs.ptr()) != 0;
    }

    pub fn isAllowed(self: *Sanitizer, which: ListKind, item: []const u8) Error!bool {
        var cs = try StackCStr.init(self.allocator, item);
        defer cs.deinit();
        return c.aether_hs_embed_is_allowed(self.handle, @intFromEnum(which), cs.ptr()) != 0;
    }

    /// Empty a list — the "start from nothing" move for a strict policy.
    pub fn clear(self: *Sanitizer, which: ListKind) bool {
        return c.aether_hs_embed_clear(self.handle, @intFromEnum(which)) != 0;
    }

    pub fn count(self: *Sanitizer, which: ListKind) usize {
        const n = c.aether_hs_embed_count(self.handle, @intFromEnum(which));
        return if (n < 0) 0 else @intCast(n);
    }

    /// The item at `index`, or `""` when out of range. Caller frees.
    pub fn itemAt(self: *Sanitizer, which: ListKind, index: usize) Error![]u8 {
        return takeString(self.allocator, c.aether_hs_embed_item_at(self.handle, @intFromEnum(which), @intCast(index)));
    }

    /// Enumerate a whole list. Caller frees both the slice and each string —
    /// `freeItems` does both.
    ///
    /// Order is the engine's own (unspecified but stable between mutations).
    /// Sort it yourself if you need determinism; the conformance suite does.
    pub fn items(self: *Sanitizer, which: ListKind) Error![][]u8 {
        const n = self.count(which);
        const out = self.allocator.alloc([]u8, n) catch return Error.OutOfMemory;
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |s| self.allocator.free(s);
            self.allocator.free(out);
        }
        while (filled < n) : (filled += 1) {
            out[filled] = try self.itemAt(which, filled);
        }
        return out;
    }

    pub fn freeItems(self: *Sanitizer, list: [][]u8) void {
        for (list) |s| self.allocator.free(s);
        self.allocator.free(list);
    }

    // ---- hook registration ----

    /// Install (or replace) the hook set.
    ///
    /// Registration passes `self` as the ABI's `user_data`, which the
    /// trampolines unpack back into a `*Sanitizer`. A hook left null in
    /// `hooks` is *cleared* engine-side rather than left dangling — otherwise
    /// replacing a full hook set with a partial one would leave the old
    /// trampoline registered, and it would then read a null field and be
    /// harmless-but-confusing. Clearing keeps engine state and Zig state in
    /// exact correspondence.
    ///
    /// ## Why this only calls the ABI when a slot's state CHANGES
    ///
    /// There is a confirmed leak in the engine: `swap_hook` in
    /// `core/embed.ae` calls `hs_embed_cb_free_env(old)`, which frees the
    /// box's `env` but deliberately not the box itself ("the engine's
    /// heap.free() on the hook slot does that") — and on the *replace* path
    /// nothing ever frees that old box. Every re-registration of an
    /// already-registered slot therefore leaks 16 bytes. It reproduces in
    /// pure C with no binding involved (see the README).
    ///
    /// We cannot fix the engine from here, but we can decline to provoke it.
    /// The trampoline pointer for a given slot is a compile-time constant, so
    /// re-registering a slot that is already registered is a semantic no-op
    /// that buys nothing and leaks a box. Tracking which slots are live lets
    /// us skip those calls entirely: the ABI is touched only when a hook goes
    /// null -> set or set -> null. That makes repeated `setHooks` calls
    /// leak-free, which is what a caller reconfiguring between documents
    /// actually does.
    pub fn setHooks(self: *Sanitizer, hooks: Hooks) void {
        const h = self.handle;
        const ud: ?*anyopaque = @ptrCast(self);

        // Set the Zig-side state FIRST. The engine reads `self.hooks` from
        // inside the trampolines, so a slot that is about to be registered
        // must already have its function in place.
        self.hooks = hooks;

        inline for (.{
            .{ "removing_tag", c.aether_hs_embed_on_removing_tag, &trampRemovingTag },
            .{ "removing_attribute", c.aether_hs_embed_on_removing_attribute, &trampRemovingAttribute },
            .{ "removing_style", c.aether_hs_embed_on_removing_style, &trampRemovingStyle },
            .{ "removing_comment", c.aether_hs_embed_on_removing_comment, &trampRemovingComment },
            .{ "post_process_node", c.aether_hs_embed_on_post_process_node, &trampPostProcessNode },
            .{ "post_process_dom", c.aether_hs_embed_on_post_process_dom, &trampPostProcessDom },
            .{ "filter_url", c.aether_hs_embed_on_filter_url, &trampFilterUrl },
        }) |slot| {
            const name = slot[0];
            const register = slot[1];
            const tramp = slot[2];
            const want = @field(hooks, name) != null;
            if (want != @field(self.registered, name)) {
                register(h, if (want) @ptrCast(tramp) else null, ud);
                @field(self.registered, name) = want;
            }
        }
    }

    /// Remove every hook. Equivalent to `setHooks(.{})`.
    pub fn resetHooks(self: *Sanitizer) void {
        self.clearHooks();
    }
};

// =========================================================================
// One-shot convenience
// =========================================================================

/// Sanitize with default policy and no hooks, creating and releasing a handle
/// around the call. Caller frees the result.
pub fn sanitize(allocator: std.mem.Allocator, html: []const u8, base_url: []const u8) Error![]u8 {
    const s = try Sanitizer.init(allocator);
    defer s.deinit();
    return s.sanitize(html, base_url);
}

test {
    // Pull the conformance suite into `zig build test`.
    _ = @import("conformance.zig");
}
