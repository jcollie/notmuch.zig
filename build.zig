const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("notmuch", .{
        .root_source_file = b.path("src/notmuch.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    module.linkSystemLibrary("notmuch", .{});

    const tests = b.addTest(.{
        .root_source_file = b.path("src/notmuch.zig"),
        .target = target,
        .optimize = optimize,
    });

    tests.linkSystemLibrary2("notmuch", .{});
    tests.linkLibC();

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
