//! Build for the Zig binding.
//!
//! This binding LINKS the sanitizer core (like Go's cgo binding, unlike the
//! dlopen-based Python/Ruby ones), so `libhtmlsanitizer.so` must exist at
//! *build* time. Everything below is about telling the linker where it is at
//! build time AND baking an rpath so the produced binary finds it at run
//! time without an `LD_LIBRARY_PATH` incantation.
//!
//! Sanitizer core search order (first hit wins):
//!   1. `-Dengine=/abs/path/to/libhtmlsanitizer.so`  — what `.tests.ae` uses,
//!      passing the artifact path `aeb` published for `core/.build.ae`.
//!   2. `$HTMLSANITIZER_LIB` — the same env var every other binding honours.
//!   3. `zig/native/`  — a staged local copy, for a distributable build.
//!   4. `../core/native/` — the in-tree monorepo layout.
//!
//! Both a directory and a full path to the `.so` are accepted for 1 and 2,
//! because half the repo's tooling hands out one and half the other; guessing
//! wrong should not be a linker error the user has to decode.
//!
//!     zig build test                       # in-tree, sanitizer core already built
//!     zig build test -Dengine=/path/to.so  # explicit
//!     zig build example                    # run the demo

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const engine_opt = b.option([]const u8, "engine", "Path to libhtmlsanitizer.so (or the directory holding it)");
    const dirs = engineSearchPath(b, engine_opt);

    // The module, so a downstream package can `@import("htmlsanitizer")`.
    // Note it is the *consumer's* build that must link the sanitizer core — a module
    // carries source, not link flags — which the README spells out.
    _ = b.addModule("htmlsanitizer", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- the conformance suite ----
    //
    // src/root.zig's trailing `test { _ = @import("conformance.zig"); }`
    // pulls the suite in, so one test artifact covers both files.
    // Zig 0.16 takes a *module* here; through 0.13 these were flat fields on
    // the options struct (.root_source_file/.target/.optimize).
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkEngine(b, tests, dirs);

    const run_tests = b.addRunArtifact(tests);
    // Never serve a cached "success" for a test whose only real dependency —
    // the sanitizer core .so — Zig's build graph cannot see. A stale pass here would
    // be worse than a slow one.
    run_tests.has_side_effects = true;

    const test_step = b.step("test", "Run the 12-check conformance suite");
    test_step.dependOn(&run_tests.step);

    // ---- the example ----
    const example_mod = b.createModule(.{
        .root_source_file = b.path("example/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("htmlsanitizer", b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const example = b.addExecutable(.{
        .name = "htmlsanitizer-example",
        .root_module = example_mod,
    });
    linkEngine(b, example, dirs);
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    const example_step = b.step("example", "Build and run the example");
    example_step.dependOn(&run_example.step);
}

/// Wire one compile step up to the sanitizer core: libc (the ABI is C), the search
/// directories, the library itself, and an rpath so the result runs in place.
fn linkEngine(b: *std.Build, step: *std.Build.Step.Compile, dirs: []const []const u8) void {
    // Zig 0.16 moved the link surface onto the MODULE; through 0.13 these were
    // methods on the Compile step itself (step.linkLibC(), step.addRPath(), …).
    const mod = step.root_module;
    // `extern "c"` declarations and `std.heap.c_allocator` both need libc.
    mod.link_libc = true;
    for (dirs) |d| {
        mod.addLibraryPath(.{ .cwd_relative = d });
        // rpath as well as -L: without it the test binary links fine and then
        // dies in the dynamic loader, which is a much more confusing failure
        // than a missing-library link error.
        mod.addRPath(.{ .cwd_relative = d });
    }
    mod.linkSystemLibrary("htmlsanitizer", .{});
    _ = b;
}

/// Resolve the sanitizer core search path, most-specific first. Returns directories.
fn engineSearchPath(b: *std.Build, engine_opt: ?[]const u8) []const []const u8 {
    // Zig 0.16's ArrayList is UNMANAGED: no .init(allocator), and every
    // mutating call takes the allocator. Through 0.13 this was
    // `std.ArrayList(T).init(b.allocator)` with allocator-free appends.
    const gpa = b.allocator;
    var dirs: std.ArrayList([]const u8) = .empty;

    if (engine_opt) |e| dirs.append(gpa, asDir(b, e)) catch @panic("OOM");
    if (b.graph.environ_map.get("HTMLSANITIZER_LIB")) |e| {
        if (e.len > 0) dirs.append(gpa, asDir(b, e)) catch @panic("OOM");
    }
    // A staged copy next to this build file, then the in-tree monorepo path.
    dirs.append(gpa, b.pathFromRoot("native")) catch @panic("OOM");
    dirs.append(gpa, b.pathFromRoot("../core/native")) catch @panic("OOM");

    return dirs.toOwnedSlice(gpa) catch @panic("OOM");
}

/// Accept either a directory or a path to the `.so` itself.
fn asDir(b: *std.Build, path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".so") or
        std.mem.endsWith(u8, path, ".dylib") or
        std.mem.endsWith(u8, path, ".dll"))
    {
        return std.fs.path.dirname(path) orelse ".";
    }
    _ = b;
    return path;
}
