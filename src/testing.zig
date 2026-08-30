// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Test support: builds a throwaway notmuch database from a small embedded
//! corpus of email messages, so unit tests can exercise the bindings against
//! real indexed mail. Only usable from tests — `std.testing.tmpDir` asserts
//! that it is running in a test build.

const std = @import("std");

const Database = @import("Database.zig");

pub const CorpusMessage = struct {
    filename: []const u8,
    data: []const u8,
};

/// A small fixed corpus: a two-message thread and two standalone messages.
pub const corpus = [_]CorpusMessage{
    .{ .filename = "one.eml", .data = @embedFile("testdata/one.eml") },
    .{ .filename = "two.eml", .data = @embedFile("testdata/two.eml") },
    .{ .filename = "three.eml", .data = @embedFile("testdata/three.eml") },
    .{ .filename = "four.eml", .data = @embedFile("testdata/four.eml") },
};

pub const TestDatabase = struct {
    tmp: std.testing.TmpDir,
    database: Database,

    pub fn deinit(self: *TestDatabase) void {
        self.database.deinit() catch {};
        self.tmp.cleanup();
    }
};

/// Create a notmuch database in a temporary directory and index the embedded
/// corpus into it. The database is open in read-write mode. Callers own the
/// result and must call `deinit` to close the database and remove the
/// temporary directory.
pub fn corpusDatabase() !TestDatabase {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();

    try tmp.dir.createDir(io, "mail", .default_dir);
    try tmp.dir.createDir(io, "mail/cur", .default_dir);
    try tmp.dir.createDir(io, "mail/new", .default_dir);
    try tmp.dir.createDir(io, "mail/tmp", .default_dir);

    var dir_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &dir_name_buf);
    const dir_name = dir_name_buf[0..len];

    const database_path = try std.fs.path.joinZ(alloc, &.{ dir_name, "mail" });
    defer alloc.free(database_path);

    {
        var cfg = try tmp.dir.createFile(io, "config", .{});
        defer cfg.close(io);

        var buf: [64]u8 = undefined;
        var file_writer = cfg.writer(io, &buf);
        const writer = &file_writer.interface;

        try writer.print(
            \\[database]
            \\path={s}
            \\mail_root={s}
            \\[user]
            \\primary_email=zig@example.org
            \\[new]
            \\[search]
            \\[maildir]
            \\
        ,
            .{ database_path, database_path },
        );
        try writer.flush();
    }

    for (corpus) |message| {
        const sub_path = try std.fs.path.join(alloc, &.{ "mail", "cur", message.filename });
        defer alloc.free(sub_path);
        try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = message.data });
    }

    const config_path = try std.fs.path.joinZ(alloc, &.{ dir_name, "config" });
    defer alloc.free(config_path);

    const database = switch (Database.create(.{ .config_path = config_path })) {
        .ok => |database| database,
        .err => |e| {
            defer e.deinit();
            return e.err;
        },
    };
    errdefer database.deinit() catch {};

    for (corpus) |message| {
        const path = try std.fs.path.joinZ(alloc, &.{ dir_name, "mail", "cur", message.filename });
        defer alloc.free(path);
        try database.indexFile(path, null);
    }

    return .{ .tmp = tmp, .database = database };
}

test corpusDatabase {
    var test_db = try corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const query = try db.queryCreate("*");
    defer query.deinit();
    try std.testing.expectEqual(@as(u32, corpus.len), try query.countMessages());
    try std.testing.expectEqual(@as(u32, 3), try query.countThreads());

    const message = try db.findMessage("two@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try std.testing.expectEqualStrings(
        "Re: Lunch plans",
        message.getHeader("Subject") orelse return error.TestUnexpectedResult,
    );
}
