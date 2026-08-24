//! The 12-check binding conformance suite (docs/conformance.md).
//!
//! Proves the Zig binding marshals every value shape across the FFI. It is
//! NOT a sanitizer test suite — the behavioural cases live in the engine's
//! own tests (`core_tests/`) and run once, in Aether. Here we only ask: does
//! each *kind of value* cross the boundary intact?
//!
//! Checks 10 and 11 — the callback trampoline with cancel semantics, and the
//! string-returning `filter_url` — are the ones a binding is most likely to
//! get subtly wrong. Zig can express both natively (`callconv(.c)` plus an
//! explicit `*anyopaque` context), so **this binding skips nothing**.
//!
//! Every test uses `std.testing.allocator`, which fails the test on a leak.
//! That is deliberate and load-bearing: it turns rule 1 of the binding (every
//! ABI-returned `char*` must go back through `free_string`) into something
//! the suite actually enforces, rather than something a comment asserts.

const std = @import("std");
const hs = @import("root.zig");
const testing = std.testing;

const alloc = testing.allocator;

/// Sanitize and assert, freeing the result. The `defer` here is what makes a
/// forgotten free show up as a test failure rather than a slow leak.
fn expectSanitize(s: *hs.Sanitizer, html: []const u8, base: []const u8, want: []const u8) !void {
    const got = try s.sanitize(html, base);
    defer alloc.free(got);
    try testing.expectEqualStrings(want, got);
}

// =========================================================================
// The twelve
// =========================================================================

test "01 script removed" {
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    try expectSanitize(s, "<div>Hello <script>alert(1)</script> world!</div>", "", "<div>Hello  world!</div>");
}

test "02 onclick removed" {
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    try expectSanitize(s, "<div onclick=\"alert(1)\">Hello</div>", "", "<div>Hello</div>");
}

test "03 empty string" {
    // The classic NULL-vs-"" bug: a binding that treats a null return as an
    // error, or that skips the call for empty input, passes everything else
    // and fails only here.
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    try expectSanitize(s, "", "", "");
}

test "04 utf8 round trip" {
    // Bytes in, bytes out. Zig slices are byte slices with no encoding
    // attached, so the only way to fail this is to mangle the length or
    // truncate at a high byte.
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    try expectSanitize(s, "<div>café ☕</div>", "", "<div>café ☕</div>");
}

test "05 allow custom tag" {
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    try expectSanitize(s, "<my-widget>x</my-widget>", "", "");
    try testing.expect(try s.allow(.tags, "my-widget"));
    try expectSanitize(s, "<my-widget>x</my-widget>", "", "<my-widget>x</my-widget>");
}

test "06 disallow tag" {
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    try expectSanitize(s, "<div>x</div>", "", "<div>x</div>");
    try testing.expect(try s.disallow(.tags, "div"));
    try expectSanitize(s, "<div>x</div>", "", "");
}

test "07 membership and count" {
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    try testing.expect(try s.isAllowed(.schemes, "http"));
    try testing.expect(!try s.isAllowed(.schemes, "gopher"));
    try testing.expectEqual(@as(usize, 2), s.count(.schemes));
}

test "08 enumeration" {
    // The item_at / MapKeys read path. Engine order is unspecified but
    // stable, so sort before comparing.
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    const list = try s.items(.schemes);
    defer s.freeItems(list);
    std.mem.sort([]u8, list, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("http", list[0]);
    try testing.expectEqualStrings("https", list[1]);
}

test "09 keep child nodes" {
    // A bool marshalled as int. Round-trip the getter too, so a binding that
    // writes the flag to the wrong slot is caught here rather than by the
    // behavioural assertion alone.
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    try expectSanitize(s, "<div><nope>Hello <span>world</span></nope></div>", "", "<div></div>");
    try testing.expect(!s.getKeepChildNodes());
    s.setKeepChildNodes(true);
    try testing.expect(s.getKeepChildNodes());
    try expectSanitize(s, "<div><nope>Hello <span>world</span></nope></div>", "", "<div>Hello <span>world</span></div>");
}

// ---- check 10: the callback trampoline + cancel semantics ----

/// Context for check 10. The engine sees only a `*anyopaque` pointing here;
/// the trampoline hands it back to the hook, which is how a Zig callback gets
/// state without a closure.
const TagSeen = struct {
    /// Fixed-size on purpose: the hook runs inside `sanitize`, where an
    /// allocation failure has nowhere to be reported. Recording into
    /// preallocated storage keeps the callback infallible.
    names: [8][32]u8 = undefined,
    lens: [8]usize = .{0} ** 8,
    reasons: [8]hs.Reason = .{.not_allowed_tag} ** 8,
    n: usize = 0,

    fn record(self: *TagSeen, name: []const u8, reason: hs.Reason) void {
        if (self.n >= self.names.len) return;
        const len = @min(name.len, self.names[self.n].len);
        @memcpy(self.names[self.n][0..len], name[0..len]);
        self.lens[self.n] = len;
        self.reasons[self.n] = reason;
        self.n += 1;
    }

    fn sawWithReason(self: *const TagSeen, name: []const u8, reason: hs.Reason) bool {
        for (0..self.n) |i| {
            if (std.mem.eql(u8, self.names[i][0..self.lens[i]], name) and self.reasons[i] == reason) return true;
        }
        return false;
    }
};

test "10 on_removing_tag cancels" {
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();

    var seen = TagSeen{};
    s.setHooks(.{
        .ctx = &seen,
        .removing_tag = struct {
            fn f(ctx: ?*anyopaque, node: hs.Node, reason: hs.Reason) bool {
                const st: *TagSeen = @ptrCast(@alignCast(ctx.?));
                // Reading the node name allocates an ABI string we must free
                // — inside a callback, exactly like anywhere else.
                const name = node.name(alloc) catch return false;
                defer alloc.free(name);
                st.record(name, reason);
                // TRUE CANCELS THE REMOVAL. This is the inversion worth
                // staring at: "return true from on_removing_tag" means KEEP.
                return std.mem.eql(u8, name, "keep-me");
            }
        }.f,
    });

    try expectSanitize(s, "<div><keep-me>a</keep-me><drop-me>b</drop-me></div>", "", "<div><keep-me>a</keep-me></div>");

    // Both tags were offered to the hook, and — this is the int-not-long
    // check — both carried reason 0 (not_allowed_tag). A binding that
    // declared `c_long` here would read a garbage reason and fail this
    // assertion even though the sanitize output above still looked right.
    try testing.expect(seen.sawWithReason("keep-me", .not_allowed_tag));
    try testing.expect(seen.sawWithReason("drop-me", .not_allowed_tag));
}

// ---- check 11: the string-returning callback (the hardest shape) ----

test "11 on_filter_url rewrites" {
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();

    s.setHooks(.{
        .filter_url = struct {
            fn f(_: ?*anyopaque, _: hs.Node, _: []const u8, resolved: []const u8) []const u8 {
                if (std.mem.eql(u8, resolved, "https://example.com/logo.png")) {
                    // A plain Zig slice. The binding copies it into an
                    // engine-owned malloc'd buffer (via hs_raw_dup) — the
                    // hook neither allocates nor frees.
                    return "https://cdn.example.net/logo.png";
                }
                // Returning `resolved` unchanged is the "no rewrite" signal,
                // and the binding forwards the original pointer so the C side
                // takes its pointer-identity fast path.
                return resolved;
            }
        }.f,
    });

    try expectSanitize(s, "<img src=\"logo.png\">", "https://example.com", "<img src=\"https://cdn.example.net/logo.png\">");
}

test "11b on_filter_url no-rewrite path" {
    // The other half of check 11: a hook that returns `resolved` untouched
    // must leave the URL exactly as the engine resolved it. This is where a
    // binding that copies unconditionally, or that frees the borrowed
    // pointer, blows up.
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();

    s.setHooks(.{
        .filter_url = struct {
            fn f(_: ?*anyopaque, _: hs.Node, _: []const u8, resolved: []const u8) []const u8 {
                return resolved;
            }
        }.f,
    });

    try expectSanitize(s, "<img src=\"logo.png\">", "https://example.com", "<img src=\"https://example.com/logo.png\">");
}

test "12 handles are independent" {
    const a = try hs.Sanitizer.init(alloc);
    defer a.deinit();
    const b = try hs.Sanitizer.init(alloc);
    defer b.deinit();

    try testing.expect(try a.allow(.tags, "only-in-a"));
    try testing.expect(try a.isAllowed(.tags, "only-in-a"));
    try testing.expect(!try b.isAllowed(.tags, "only-in-a"));
}

// =========================================================================
// Extras — the remaining callback shapes, and Zig-specific hazards
// =========================================================================

const AttrSeen = struct {
    elem: [32]u8 = undefined,
    elem_len: usize = 0,
    name: [32]u8 = undefined,
    name_len: usize = 0,
    value: [64]u8 = undefined,
    value_len: usize = 0,
    reason: hs.Reason = .not_allowed_tag,
    calls: usize = 0,
};

test "extra on_removing_attribute sees the attribute" {
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();

    var seen = AttrSeen{};
    s.setHooks(.{
        .ctx = &seen,
        .removing_attribute = struct {
            fn f(ctx: ?*anyopaque, elem: hs.Node, attr: hs.Attribute, reason: hs.Reason) bool {
                const st: *AttrSeen = @ptrCast(@alignCast(ctx.?));
                st.calls += 1;
                const en = elem.name(alloc) catch return false;
                defer alloc.free(en);
                const an = attr.name(alloc) catch return false;
                defer alloc.free(an);
                const av = attr.value(alloc) catch return false;
                defer alloc.free(av);
                st.elem_len = @min(en.len, st.elem.len);
                @memcpy(st.elem[0..st.elem_len], en[0..st.elem_len]);
                st.name_len = @min(an.len, st.name.len);
                @memcpy(st.name[0..st.name_len], an[0..st.name_len]);
                st.value_len = @min(av.len, st.value.len);
                @memcpy(st.value[0..st.value_len], av[0..st.value_len]);
                st.reason = reason;
                return false; // proceed with the removal
            }
        }.f,
    });

    try expectSanitize(s, "<div onclick=\"alert(1)\">x</div>", "", "<div>x</div>");
    try testing.expect(seen.calls >= 1);
    try testing.expectEqualStrings("div", seen.elem[0..seen.elem_len]);
    try testing.expectEqualStrings("onclick", seen.name[0..seen.name_len]);
    try testing.expectEqualStrings("alert(1)", seen.value[0..seen.value_len]);
    try testing.expectEqual(hs.Reason.not_allowed_attribute, seen.reason);
}

test "extra on_removing_comment cancels" {
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    s.setHooks(.{
        .removing_comment = struct {
            fn f(_: ?*anyopaque, _: hs.Node) bool {
                return true; // keep it
            }
        }.f,
    });
    try expectSanitize(s, "<div>a<!-- keep -->b</div>", "", "<div>a<!-- keep -->b</div>");
}

const StyleSeen = struct {
    name: [32]u8 = undefined,
    name_len: usize = 0,
    value: [32]u8 = undefined,
    value_len: usize = 0,
    calls: usize = 0,
};

test "extra on_removing_style is four-arg" {
    // The 4-arg shape (elem, name, value, reason) plus user_data — five C
    // arguments in total, which is where an off-by-one in the trampoline
    // signature shows up as shifted values rather than a crash.
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();

    var seen = StyleSeen{};
    s.setHooks(.{
        .ctx = &seen,
        .removing_style = struct {
            fn f(ctx: ?*anyopaque, _: hs.Node, name: []const u8, value: []const u8, _: hs.Reason) bool {
                const st: *StyleSeen = @ptrCast(@alignCast(ctx.?));
                st.calls += 1;
                if (std.mem.eql(u8, name, "-custom-thing")) {
                    st.name_len = @min(name.len, st.name.len);
                    @memcpy(st.name[0..st.name_len], name[0..st.name_len]);
                    st.value_len = @min(value.len, st.value.len);
                    @memcpy(st.value[0..st.value_len], value[0..st.value_len]);
                    return true; // keep this otherwise-disallowed property
                }
                return false;
            }
        }.f,
    });

    const out = try s.sanitize("<div style=\"-custom-thing: 3; color: red\">x</div>", "");
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "-custom-thing") != null);
    try testing.expect(seen.calls >= 1);
    try testing.expectEqualStrings("-custom-thing", seen.name[0..seen.name_len]);
    try testing.expectEqualStrings("3", seen.value[0..seen.value_len]);
}

const Counter = struct { n: usize = 0, kind: hs.NodeKind = .none, children: usize = 0 };

test "extra post_process_node visits nodes" {
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    var counter = Counter{};
    s.setHooks(.{
        .ctx = &counter,
        .post_process_node = struct {
            fn f(ctx: ?*anyopaque, node: hs.Node) void {
                const st: *Counter = @ptrCast(@alignCast(ctx.?));
                st.n += 1;
                st.kind = node.kind();
            }
        }.f,
    });
    const out = try s.sanitize("<div><span>a</span><span>b</span></div>", "");
    defer alloc.free(out);
    try testing.expect(counter.n > 0);
}

test "extra node tree navigation from post_process_dom" {
    // Exercises the read-only DOM accessors on a borrowed pointer: kind,
    // child count, and child indexing.
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    var counter = Counter{};
    s.setHooks(.{
        .ctx = &counter,
        .post_process_dom = struct {
            fn f(ctx: ?*anyopaque, doc: hs.Node) void {
                const st: *Counter = @ptrCast(@alignCast(ctx.?));
                st.kind = doc.kind();
                st.children = doc.childCount();
            }
        }.f,
    });
    const out = try s.sanitize("<div>a</div><p>b</p>", "");
    defer alloc.free(out);
    try testing.expectEqual(hs.NodeKind.document, counter.kind);
    try testing.expect(counter.children >= 2);
}

test "extra attr_set_value rewrites in place" {
    // Proves the ABI's "we COPY engine-side" guarantee: the value we hand in
    // lives in a stack buffer that is gone the instant the callback returns,
    // yet the rewritten attribute survives into the output.
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    s.setHooks(.{
        .post_process_node = struct {
            fn f(_: ?*anyopaque, node: hs.Node) void {
                if (node.kind() != .element) return;
                var i: usize = 0;
                while (i < node.attrCount()) : (i += 1) {
                    const attr = node.attrAt(i) orelse continue;
                    const name = attr.name(alloc) catch continue;
                    defer alloc.free(name);
                    if (std.mem.eql(u8, name, "title")) {
                        var scratch: [15]u8 = "rewritten-by-cb".*;
                        attr.setValue(alloc, &scratch) catch {};
                    }
                }
            }
        }.f,
    });
    const out = try s.sanitize("<div title=\"original\">x</div>", "");
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "rewritten-by-cb") != null);
}

test "extra hooks can be cleared" {
    // Registering, replacing, then clearing must leave the engine with no
    // dangling trampoline pointing at our struct — and the behaviour must
    // revert. This is the Zig analogue of abi_smoke.c's check 7.
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();

    const keepAll = struct {
        fn f(_: ?*anyopaque, _: hs.Node, _: hs.Reason) bool {
            return true;
        }
    }.f;

    s.setHooks(.{ .removing_tag = keepAll });
    s.setHooks(.{ .removing_tag = keepAll }); // replace — must not double-free
    try expectSanitize(s, "<div><keep-me>a</keep-me></div>", "", "<div><keep-me>a</keep-me></div>");

    s.resetHooks();
    try expectSanitize(s, "<div><keep-me>a</keep-me></div>", "", "<div></div>");
    s.resetHooks(); // clearing an already-clear slot must be a true no-op
    try expectSanitize(s, "<div><keep-me>a</keep-me></div>", "", "<div></div>");
}

test "extra repeated setHooks does not churn the engine's hook slots" {
    // Guards the workaround for the ENGINE-side leak documented on setHooks:
    // `swap_hook` never frees the old HsClosure box on the replace path, so
    // every redundant re-registration leaks 16 bytes. We only touch the ABI
    // on a real null<->set transition, which makes reconfiguring between
    // documents (a normal thing to do) leak-free.
    //
    // Behaviour must be identical either way, so assert that too: many
    // set/reset cycles, then the hook still works.
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();

    const keepMe = struct {
        fn f(_: ?*anyopaque, node: hs.Node, _: hs.Reason) bool {
            const name = node.name(alloc) catch return false;
            defer alloc.free(name);
            return std.mem.eql(u8, name, "keep-me");
        }
    }.f;

    for (0..25) |_| {
        s.setHooks(.{ .removing_tag = keepMe });
        try expectSanitize(s, "<div><keep-me>a</keep-me><x>b</x></div>", "", "<div><keep-me>a</keep-me></div>");
        s.setHooks(.{});
        try expectSanitize(s, "<div><keep-me>a</keep-me><x>b</x></div>", "", "<div></div>");
    }
}

test "extra sanitize_document is wired" {
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    const out = try s.sanitizeDocument("<div>doc<script>x</script></div>", "");
    defer alloc.free(out);
    try testing.expectEqualStrings("<html><head></head><body><div>doc</div></body></html>", out);
}

test "extra allow_data_attributes flag" {
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    try expectSanitize(s, "<div data-x=\"1\"></div>", "", "<div></div>");
    try testing.expect(!s.getAllowDataAttributes());
    s.setAllowDataAttributes(true);
    try testing.expect(s.getAllowDataAttributes());
    try expectSanitize(s, "<div data-x=\"1\"></div>", "", "<div data-x=\"1\"></div>");
}

test "extra clear empties a list" {
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 2), s.count(.schemes));
    try testing.expect(s.clear(.schemes));
    try testing.expectEqual(@as(usize, 0), s.count(.schemes));
}

test "extra item_at out of range is an owned empty string" {
    // The ABI returns an owned "" rather than null. A binding that assumes
    // null here either crashes or leaks; freeing it through the one helper
    // is what makes this safe, and testing.allocator proves we did.
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    const oob = try s.itemAt(.schemes, 999);
    defer alloc.free(oob);
    try testing.expectEqualStrings("", oob);
}

test "extra abi version" {
    try testing.expect(hs.abiVersion() >= 1);
}

test "extra interior NUL is rejected, not truncated" {
    // Zig slices happily carry a NUL; C strings do not. Silently truncating
    // would mean the engine sanitized less than the caller handed it — a
    // security bug, not a formatting one.
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();
    try testing.expectError(hs.Error.InteriorNul, s.sanitize("<div>a\x00<script>b</script></div>", ""));
    try testing.expectError(hs.Error.InteriorNul, s.allow(.tags, "bad\x00tag"));
}

test "extra one-shot helper" {
    const out = try hs.sanitize(alloc, "<div>a<script>b</script></div>", "");
    defer alloc.free(out);
    try testing.expectEqualStrings("<div>a</div>", out);
}

test "extra long input crosses the boundary intact" {
    // Exercises the allocator path in `call` (past the stack-buffer cutoff)
    // and confirms nothing truncates at 256 bytes.
    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();

    // Zig 0.16's ArrayList is unmanaged: no .init(alloc), and the allocator
    // is threaded through every mutating call.
    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(alloc);
    try html.appendSlice(alloc, "<div>");
    for (0..500) |_| try html.appendSlice(alloc, "<span>x</span>");
    try html.appendSlice(alloc, "<script>evil()</script></div>");

    const out = try s.sanitize(html.items, "");
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "script") == null);
    try testing.expectEqual(@as(usize, 500), std.mem.count(u8, out, "<span>x</span>"));
}
