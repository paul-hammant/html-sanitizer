//! A small tour of the Zig binding: `zig build example`.
//!
//! Shows the four things a caller actually needs — sanitize, policy lists,
//! flags, and a hook — with the ownership rules made explicit at every step.

const std = @import("std");
const hs = @import("htmlsanitizer");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit(); // reports a leak on exit, which is the point
    const alloc = gpa.allocator();

    const out = std.io.getStdOut().writer();
    try out.print("sanitizer core ABI version: {d}\n\n", .{hs.abiVersion()});

    const s = try hs.Sanitizer.init(alloc);
    defer s.deinit();

    // --- the basics. Every returned slice is caller-owned. ---
    {
        const clean = try s.sanitize("<div onclick=\"alert(1)\">Hello <script>evil()</script>world</div>", "");
        defer alloc.free(clean);
        try out.print("sanitize:    {s}\n", .{clean});
    }

    // --- relative URLs resolve against a base URL ---
    {
        const clean = try s.sanitize("<img src=\"logo.png\">", "https://example.com");
        defer alloc.free(clean);
        try out.print("with base:   {s}\n", .{clean});
    }

    // --- policy lists: six of them, selected by enum, not a bare int ---
    {
        _ = try s.allow(.tags, "my-widget");
        const clean = try s.sanitize("<my-widget>x</my-widget>", "");
        defer alloc.free(clean);
        try out.print("custom tag:  {s}\n", .{clean});

        const schemes = try s.items(.schemes);
        defer s.freeItems(schemes);
        try out.print("schemes:     {d} allowed\n", .{schemes.len});
    }

    // --- flags marshal as C int ---
    {
        s.setKeepChildNodes(true);
        const clean = try s.sanitize("<div><nope>kept <b>children</b></nope></div>", "");
        defer alloc.free(clean);
        try out.print("keep kids:   {s}\n", .{clean});
        s.setKeepChildNodes(false);
    }

    // --- a hook. `ctx` is how a Zig callback carries state: the sanitizer core hands
    //     it back as the first argument, so no closure allocation is needed.
    //     Returning TRUE from a removing_* hook CANCELS the removal. ---
    {
        var kept: usize = 0;
        s.setHooks(.{
            .ctx = &kept,
            .removing_tag = struct {
                fn f(ctx: ?*anyopaque, node: hs.Node, _: hs.Reason) bool {
                    const counter: *usize = @ptrCast(@alignCast(ctx.?));
                    var buf: [64]u8 = undefined;
                    var fba = std.heap.FixedBufferAllocator.init(&buf);
                    const name = node.name(fba.allocator()) catch return false;
                    if (std.mem.eql(u8, name, "keep-me")) {
                        counter.* += 1;
                        return true; // KEEP it
                    }
                    return false;
                }
            }.f,
        });

        const clean = try s.sanitize("<div><keep-me>a</keep-me><drop-me>b</drop-me></div>", "");
        defer alloc.free(clean);
        try out.print("hook:        {s}  (kept {d})\n", .{ clean, kept });
        s.resetHooks();
    }

    // --- the string-returning hook: return the URL to use. The binding
    //     copies it into an core-owned buffer; you never free it. ---
    {
        s.setHooks(.{
            .filter_url = struct {
                fn f(_: ?*anyopaque, _: hs.Node, _: []const u8, resolved: []const u8) []const u8 {
                    if (std.mem.startsWith(u8, resolved, "https://example.com/")) {
                        return "https://cdn.example.net/rewritten.png";
                    }
                    return resolved; // unchanged == "no rewrite"
                }
            }.f,
        });
        const clean = try s.sanitize("<img src=\"logo.png\">", "https://example.com");
        defer alloc.free(clean);
        try out.print("filter_url:  {s}\n", .{clean});
    }
}
