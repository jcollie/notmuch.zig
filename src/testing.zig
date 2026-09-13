// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Test support: builds a throwaway notmuch database from a small embedded
//! corpus of email messages, so unit tests can exercise the bindings against
//! real indexed mail. Only usable from tests — `std.testing.tmpDir` asserts
//! that it is running in a test build.
//!
//! The mail store is a real maildir, created and delivered into through
//! [zig-maildir](https://git.jcollie.dev/jeff/zig-maildir) rather than by
//! writing files into `cur` by hand. Each message therefore arrives in `new`
//! under a generated name that records its size and carries no maildir info
//! part — an ordinary arrival that nobody has looked at yet — which is the
//! state notmuch's flag synchronization expects to find and rename. Since
//! those names are invented at delivery time and not known in advance, tests
//! find their messages by `Message-ID` and ask the fixture for the filename
//! a message actually landed under.

const std = @import("std");

const maildir = @import("maildir");

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
    /// The message's `Message-ID` without its angle brackets. A delivered
    /// maildir name is invented at delivery time, so this — and not a
    /// filename — is how a test names the message it wants.
    id: []const u8,
    data: []const u8,
};

/// A small fixed corpus: a two-message thread and two standalone messages.
pub const corpus = [_]CorpusMessage{
    .{ .id = "one@example.org", .data = @embedFile("testdata/one.eml") },
    .{ .id = "two@example.org", .data = @embedFile("testdata/two.eml") },
    .{ .id = "three@example.org", .data = @embedFile("testdata/three.eml") },
    .{ .id = "four@example.org", .data = @embedFile("testdata/four.eml") },
};

test corpus {
    // Each corpus entry is a complete RFC 5322 message whose Message-ID is
    // the one recorded beside it, so tests can look messages up by ID.
    try std.testing.expectEqual(@as(usize, 4), corpus.len);
    for (corpus) |message| {
        var buffer: [128]u8 = undefined;
        const header = try std.fmt.bufPrint(&buffer, "Message-ID: <{s}>", .{message.id});
        try std.testing.expect(std.mem.indexOf(u8, message.data, header) != null);
    }
}

pub const TestDatabase = struct {
    tmp: std.testing.TmpDir,
    /// The mail store the database indexes, open for delivery.
    mailbox: maildir.Maildir,
    database: Database,
    /// Where each corpus message landed, in corpus order.
    delivered: [corpus.len]maildir.Message,

    pub fn deinit(self: *TestDatabase) void {
        self.database.deinit() catch {};
        self.mailbox.close(std.testing.io);
        self.tmp.cleanup();
    }

    /// Deliver a message into the mail store, without indexing it — indexing
    /// is generally what the calling test is exercising. `options` says where
    /// it lands and with which maildir flags; the default is `new` with none,
    /// an ordinary arrival.
    pub fn deliver(
        self: *TestDatabase,
        data: []const u8,
        options: maildir.Maildir.DeliverOptions,
    ) !maildir.Message {
        return self.mailbox.deliver(std.testing.io, data, options);
    }

    /// The absolute path of a message in the mail store. The caller owns the
    /// result and must free it with `std.testing.allocator`.
    pub fn pathOf(self: *const TestDatabase, message: *const maildir.Message) ![:0]u8 {
        const root = self.database.getPath() orelse return error.TestUnexpectedResult;
        return std.fs.path.joinZ(
            std.testing.allocator,
            &.{ root, message.subdir.dirname(), message.filename() },
        );
    }

    /// The absolute path of the corpus message at `index`. The caller owns
    /// the result and must free it with `std.testing.allocator`.
    pub fn path(self: *const TestDatabase, index: usize) ![:0]u8 {
        return self.pathOf(&self.delivered[index]);
    }

    /// The name — the basename only — the corpus message at `index` was
    /// delivered under.
    pub fn filename(self: *const TestDatabase, index: usize) []const u8 {
        return self.delivered[index].filename();
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

    /// The name the message has in the mail store's `tmp` directory while it
    /// is being written. See `helpers.MessageWriter.tempName`.
    pub fn tempName(self: *const TestMessageWriter) []const u8 {
        return self.inner.tempName();
    }

    /// Discard the message without delivering or indexing it, and free the
    /// helper's resources.
    pub fn cancel(self: *TestMessageWriter) void {
        self.inner.cancel();
        std.testing.allocator.free(self.buffer);
        self.* = undefined;
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

    // A real maildir: `tmp`, `new` and `cur`, created in the order the
    // specification asks for.
    var mailbox = try maildir.Maildir.create(tmp.dir, io, "mail", .{});
    errdefer mailbox.close(io);

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

    // Delivered rather than copied into place: each message is written into
    // `tmp` under a name nothing else will invent and renamed into `new` once
    // it is whole, which is the only way a maildir is safe to write.
    var delivered: [corpus.len]maildir.Message = undefined;
    for (corpus, &delivered) |message, *slot|
        slot.* = try mailbox.deliver(io, message.data, .{});

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

    for (&delivered) |*message| {
        const path = try std.fs.path.joinZ(
            alloc,
            &.{ dir_name, "mail", message.subdir.dirname(), message.filename() },
        );
        defer alloc.free(path);
        try database.indexFile(path, null);
    }

    return .{
        .tmp = tmp,
        .mailbox = mailbox,
        .database = database,
        .delivered = delivered,
    };
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

test TestDatabase {
    var test_db = try corpusDatabase();
    defer test_db.deinit();
    const alloc = std.testing.allocator;

    // Every corpus message was delivered into `new` under a generated name
    // recording its size, and the database found it there.
    for (corpus, 0..) |message, index| {
        const name: maildir.Name = .parse(test_db.filename(index), ':');
        try std.testing.expectEqual(@as(?u64, message.data.len), name.size());
        try std.testing.expectEqual(maildir.Name.Info.none, std.meta.activeTag(name.info));

        const path = try test_db.path(index);
        defer alloc.free(path);
        try std.testing.expect(std.mem.indexOf(u8, path, "/new/") != null);

        const found = try test_db.database.findMessageByFilename(path) orelse
            return error.TestUnexpectedResult;
        defer found.deinit();
        try std.testing.expectEqualStrings(message.id, found.getMessageID() orelse "");
    }

    // Delivery through the fixture puts mail in the store that the database
    // does not know about until something indexes it.
    const extra = try test_db.deliver(corpus[0].data, .{ .to = .{ .cur = .{ .seen = true } } });
    try std.testing.expect(extra.flags().seen);
    const extra_path = try test_db.pathOf(&extra);
    defer alloc.free(extra_path);
    try std.testing.expectEqual(
        @as(?Message, null),
        try test_db.database.findMessageByFilename(extra_path),
    );
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
