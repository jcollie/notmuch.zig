// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Convenience helpers layered on top of the bindings.
//!
//! Unlike the rest of the library, these do not wrap libnotmuch APIs
//! directly; they compose the bindings with the Zig standard library.

const std = @import("std");

const Database = @import("Database.zig");
const IndexOpts = @import("IndexOpts.zig");
const Message = @import("Message.zig");

/// Reads the contents of a message from the mail store through a
/// `std.Io.Reader`.
///
/// The content is read from the file backing the message. For a message
/// stored under multiple filenames (identical message IDs), the file
/// reported by `Message.getFilename` — an arbitrary one of them — is opened.
///
/// `buffer` is caller-owned and must remain valid until `deinit` is called.
pub const MessageReader = struct {
    file_reader: std.Io.File.Reader,

    /// Open the file backing `message` for reading. Reads are buffered
    /// through `buffer`.
    pub fn init(io: std.Io, message: Message, buffer: []u8) !MessageReader {
        const file = try std.Io.Dir.openFileAbsolute(io, try message.getFilename(), .{});
        return .{ .file_reader = file.reader(io, buffer) };
    }

    /// The `std.Io.Reader` producing the raw message content.
    pub fn reader(self: *MessageReader) *std.Io.Reader {
        return &self.file_reader.interface;
    }

    /// Close the message file.
    pub fn deinit(self: *MessageReader) void {
        self.file_reader.file.close(self.file_reader.io);
        self.* = undefined;
    }
};

test MessageReader {
    const fixture = @import("testing.zig");
    const alloc = std.testing.allocator;

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    var buffer: [256]u8 = undefined;
    var message_reader = try MessageReader.init(std.testing.io, message, &buffer);
    defer message_reader.deinit();

    // The reader produces the raw message content, byte for byte.
    const content = try message_reader.reader().allocRemaining(alloc, .unlimited);
    defer alloc.free(content);
    try std.testing.expectEqualStrings(fixture.corpus[0].data, content);
}

/// The maildir subdirectory a message is delivered into.
pub const Subdir = enum {
    /// Mail that has not yet been seen by the user.
    new,
    /// Mail the user has already seen. Files delivered here carry an empty
    /// `:2,` maildir info suffix, ready for flag synchronization.
    cur,
};

pub const Options = struct {
    /// Which maildir subdirectory the message is delivered into.
    subdir: Subdir = .new,
};

/// Streams an email into a notmuch database: the message is composed through
/// a `std.Io.Writer` into the mail store, then indexed.
///
/// A unique maildir filename is generated for the message — prefixed with
/// the current time so that filenames sort in arrival order, like those
/// written by notmuch insert — and delivered into the mail root's `new` or
/// `cur` subdirectory according to `Options.subdir`. The message is written through `std.Io.File.Atomic`, so
/// no partially written file is ever visible in the mail store: the email
/// accumulates in an unnamed ephemeral file and is atomically materialized
/// by `finish` before indexing. `cancel` discards it without a trace.
///
/// `buffer` is caller-owned and must remain valid until `finish` or `cancel`
/// is called.
pub const MessageWriter = struct {
    database: Database,
    dir: std.Io.Dir,
    atomic: std.Io.File.Atomic,
    file_writer: std.Io.File.Writer,
    subdir: Subdir,
    name_buf: [name_capacity]u8,
    name_len: usize,

    const name_capacity = 64;

    /// Prepare to stream an email into the database's mail store. Writes are
    /// buffered through `buffer`.
    pub fn init(io: std.Io, database: Database, buffer: []u8, options: Options) !MessageWriter {
        const root = database.getPath() orelse return error.NoDatabasePath;

        var mw: MessageWriter = undefined;
        mw.database = database;
        mw.subdir = options.subdir;

        const suffix: []const u8 = switch (options.subdir) {
            .new => "",
            .cur => ":2,",
        };
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        const micros = std.Io.Timestamp.now(io, .real).toMicroseconds();
        // Lead with the delivery time, like notmuch insert's
        // <seconds>.M<microseconds>P<pid>.<hostname> names, so that sorting
        // new/ by filename approximates arrival order.
        const name = std.fmt.bufPrint(&mw.name_buf, "{d}.M{d}R{x:0>16}.notmuch-zig{s}", .{
            @divTrunc(micros, std.time.us_per_s),
            @mod(micros, std.time.us_per_s),
            std.mem.readInt(u64, &random_bytes, .big),
            suffix,
        }) catch unreachable;
        mw.name_len = name.len;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&path_buf, "{s}/{t}", .{ root, options.subdir }) catch
            return error.NameTooLong;
        mw.dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
        errdefer mw.dir.close(io);
        mw.atomic = try mw.dir.createFileAtomic(io, name, .{});
        mw.file_writer = mw.atomic.file.writer(io, buffer);
        return mw;
    }

    /// The `std.Io.Writer` to compose the email into.
    pub fn writer(self: *MessageWriter) *std.Io.Writer {
        return &self.file_writer.interface;
    }

    /// The generated maildir filename (the basename only) the message will
    /// be delivered under.
    ///
    /// The returned slice points into the writer and is invalidated by
    /// `finish` and `cancel`; copy it if it is needed afterwards. After a
    /// successful `finish`, `Message.getFilename` on the returned message
    /// reports the full delivered path.
    pub fn filename(self: *const MessageWriter) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    test filename {
        const fixture = @import("testing.zig");

        var test_db = try fixture.corpusDatabase();
        defer test_db.deinit();
        var buffer: [256]u8 = undefined;

        // The generated name leads with the delivery timestamp so filenames
        // sort by arrival, like those written by notmuch insert.
        var mw = try MessageWriter.init(std.testing.io, test_db.database, &buffer, .{});
        try std.testing.expect(std.ascii.isDigit(mw.filename()[0]));
        try std.testing.expect(std.mem.indexOf(u8, mw.filename(), ".M") != null);

        var name_buf: [name_capacity]u8 = undefined;
        const name = name_buf[0..mw.filename().len];
        @memcpy(name, mw.filename());

        try mw.writer().writeAll(
            \\From: Ivan <ivan@example.org>
            \\To: Alice <alice@example.org>
            \\Subject: Delivered under a generated name
            \\Date: Sun, 07 Apr 2024 08:00:00 +0000
            \\Message-ID: <nine@example.org>
            \\
            \\Short.
            \\
        );
        const message = try mw.finish(null);
        defer message.deinit();

        // The indexed message was delivered under exactly that name.
        try std.testing.expectEqualStrings(name, std.fs.path.basename(try message.getFilename()));
    }

    /// Flush the email, atomically materialize it in the mail store, index
    /// it into the database, and return the indexed message. The caller owns
    /// the returned message. The database must be open in read-write mode.
    pub fn finish(self: *MessageWriter, indexopts: ?IndexOpts) !Message {
        const io = self.file_writer.io;
        defer {
            self.atomic.deinit(io);
            self.dir.close(io);
            self.* = undefined;
        }
        try self.file_writer.interface.flush();

        // The struct (and the name buffer inside it) may have moved since
        // init, so re-point the atomic file's destination before linking.
        self.atomic.dest_sub_path = self.filename();
        try self.atomic.link(io);

        const root = self.database.getPath() orelse return error.NoDatabasePath;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{t}/{s}", .{ root, self.subdir, self.filename() }) catch
            return error.NameTooLong;
        return self.database.indexFileGetMessage(path, indexopts);
    }

    /// Discard the partially written email without indexing it. Nothing ever
    /// appears in the mail store.
    pub fn cancel(self: *MessageWriter) void {
        const io = self.file_writer.io;
        self.atomic.deinit(io);
        self.dir.close(io);
        self.* = undefined;
    }

    test cancel {
        const fixture = @import("testing.zig");
        const io = std.testing.io;

        var test_db = try fixture.corpusDatabase();
        defer test_db.deinit();
        var buffer: [256]u8 = undefined;

        // A cancelled message leaves nothing behind at its destination.
        var mw = try MessageWriter.init(io, test_db.database, &buffer, .{ .subdir = .new });
        try mw.writer().writeAll("From: partial <partial@example.org>\n");
        var path_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "mail/new/{s}", .{mw.filename()});
        mw.cancel();
        try std.testing.expectError(error.FileNotFound, test_db.tmp.dir.access(io, path, .{}));
    }
};

test MessageWriter {
    const fixture = @import("testing.zig");

    const io = std.testing.io;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;
    var buffer: [256]u8 = undefined;

    // A finished message is materialized in new/ and indexed.
    var finished = try MessageWriter.init(io, db, &buffer, .{ .subdir = .new });
    try finished.writer().writeAll(
        \\From: Grace <grace@example.org>
        \\To: Alice <alice@example.org>
        \\Subject: Atomic delivery
        \\Date: Sat, 06 Apr 2024 09:00:00 +0000
        \\Message-ID: <seven@example.org>
        \\
        \\Materialized atomically.
        \\
    );
    const message = try finished.finish(null);
    defer message.deinit();
    try std.testing.expectEqualStrings("seven@example.org", message.getMessageID() orelse "");
    try std.testing.expect(std.mem.indexOf(u8, try message.getFilename(), "/new/") != null);

    // Delivery into cur/ carries an empty maildir info suffix.
    var seen = try MessageWriter.init(io, db, &buffer, .{ .subdir = .cur });
    try seen.writer().writeAll(
        \\From: Heidi <heidi@example.org>
        \\To: Alice <alice@example.org>
        \\Subject: Already seen
        \\Date: Sat, 06 Apr 2024 10:00:00 +0000
        \\Message-ID: <eight@example.org>
        \\
        \\Delivered as seen mail.
        \\
    );
    const seen_message = try seen.finish(null);
    defer seen_message.deinit();
    const seen_filename = try seen_message.getFilename();
    try std.testing.expect(std.mem.indexOf(u8, seen_filename, "/cur/") != null);
    try std.testing.expect(std.mem.endsWith(u8, seen_filename, ":2,"));
}
