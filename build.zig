// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const notmuch_c = b.addTranslateC(.{
        .root_source_file = b.path("src/notmuch.c"),
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });
    if (b.graph.environ_map.get("NOTMUCH_INCLUDE")) |path|
        notmuch_c.addIncludePath(.{ .cwd_relative = path });

    const notmuch_zig = b.addModule("notmuch", .{
        .root_source_file = b.path("src/notmuch.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    notmuch_zig.addImport("c", notmuch_c.createModule());
    notmuch_zig.linkSystemLibrary("notmuch", .{});

    const tests = b.addTest(.{
        .root_module = notmuch_zig,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const notmuch_lib = b.addLibrary(.{
        .name = "notmuch",
        .root_module = notmuch_zig,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = notmuch_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Build the API docs");
    docs_step.dependOn(&install_docs.step);
}
