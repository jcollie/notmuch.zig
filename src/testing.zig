// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Test support: builds a throwaway notmuch database from a small embedded
//! corpus of email messages, so unit tests can exercise the bindings against
//! real indexed mail. Only usable from tests — `std.testing.tmpDir` asserts
//! that it is running in a test build.

const std = @import("std");

const Database = @import("Database.zig");
const helpers = @import("helpers.zig");
const Message = @import("Message.zig");
const TagsIterator = @import("TagsIterator.zig");

/// Consume a tags iterator and report whether it yields `name`.
pub fn hasTag(tags: *TagsIterator, name: []const u8) bool {
    defer tags.deinit();
    while (tags.next()) |tag| {
        if (std.mem.eql(u8, tag, name)) return true;
    }
    return false;
}

test hasTag {
    var test_db = try corpusDatabase();
    defer test_db.deinit();

    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try message.addTag("inbox");

    // hasTag consumes (and deinitializes) the iterator, so fetch a fresh
    // one for each check.
    var tags = message.getTags();
    try std.testing.expect(hasTag(&tags, "inbox"));
    tags = message.getTags();
    try std.testing.expect(!hasTag(&tags, "archive"));
}

/// Consume a tags iterator and count its entries.
pub fn countTags(tags: *TagsIterator) usize {
    defer tags.deinit();
    var n: usize = 0;
    while (tags.next()) |_| n += 1;
    return n;
}

test countTags {
    var test_db = try corpusDatabase();
    defer test_db.deinit();

    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    var tags = message.getTags();
    try std.testing.expectEqual(@as(usize, 0), countTags(&tags));

    try message.addTag("alpha");
    try message.addTag("beta");
    tags = message.getTags();
    try std.testing.expectEqual(@as(usize, 2), countTags(&tags));
}

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

test corpus {
    // Each corpus entry is a complete RFC 5322 message with a stable
    // Message-ID, so tests can look messages up by ID.
    try std.testing.expectEqual(@as(usize, 4), corpus.len);
    for (corpus) |message| {
        try std.testing.expect(std.mem.indexOf(u8, message.data, "Message-ID: <") != null);
        try std.testing.expect(std.mem.endsWith(u8, message.filename, ".eml"));
    }
}

pub const TestDatabase = struct {
    tmp: std.testing.TmpDir,
    database: Database,

    pub fn deinit(self: *TestDatabase) void {
        self.database.deinit() catch {};
        self.tmp.cleanup();
    }

    /// Begin streaming a new message into the maildir using
    /// `helpers.MessageWriter`, with the write buffer managed by the test
    /// allocator. Compose the email through `TestMessageWriter.writer`, then
    /// call `TestMessageWriter.finish` to index it.
    pub fn newMessage(self: *TestDatabase, options: helpers.Options) !TestMessageWriter {
        const alloc = std.testing.allocator;

        const buffer = try alloc.alloc(u8, 4096);
        errdefer alloc.free(buffer);

        return .{
            .inner = try helpers.MessageWriter.init(std.testing.io, self.database, buffer, options),
            .buffer = buffer,
        };
    }
};

/// An email being streamed into the test database. Obtained from
/// `TestDatabase.newMessage`; wraps `helpers.MessageWriter` and owns its
/// write buffer.
pub const TestMessageWriter = struct {
    inner: helpers.MessageWriter,
    buffer: []u8,

    /// The `std.Io.Writer` to compose the email into.
    pub fn writer(self: *TestMessageWriter) *std.Io.Writer {
        return self.inner.writer();
    }

    /// Flush and close the message file, index it into the database, and
    /// return the indexed message. Frees the helper's resources; the caller
    /// owns the returned message.
    pub fn finish(self: *TestMessageWriter) !Message {
        const alloc = std.testing.allocator;
        defer {
            alloc.free(self.buffer);
            self.* = undefined;
        }
        return self.inner.finish(null);
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

test TestMessageWriter {
    var test_db = try corpusDatabase();
    defer test_db.deinit();

    var message_writer = try test_db.newMessage(.{});
    const w = message_writer.writer();
    try w.print(
        \\From: Frank <frank@example.org>
        \\To: Alice <alice@example.org>
        \\Subject: {s}
        \\Date: Fri, 05 Apr 2024 12:00:00 +0000
        \\Message-ID: <six@example.org>
        \\
        \\Written through a std.Io.Writer.
        \\
    , .{"Streamed message"});

    const message = try message_writer.finish();
    defer message.deinit();
    try std.testing.expectEqualStrings("six@example.org", message.getMessageID() orelse "");

    const query = try test_db.database.queryCreate("subject:streamed");
    defer query.deinit();
    try std.testing.expectEqual(@as(u32, 1), try query.countMessages());
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
