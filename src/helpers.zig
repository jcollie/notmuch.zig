// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Convenience helpers layered on top of the bindings.
//!
//! Unlike the rest of the library, these do not wrap libnotmuch APIs
//! directly; they compose the bindings with the Zig standard library.

const std = @import("std");

const maildir = @import("maildir");

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

/// Where a message being written is delivered: `new`, for mail nobody has
/// looked at, or `cur` with the maildir flags it already carries — which is
/// what an IMAP `APPEND` of an already-read message, or a client saving a
/// draft, does.
pub const Destination = maildir.Maildir.Destination;

pub const Options = struct {
    /// Which maildir directory the message is delivered into, and with what
    /// flags.
    to: Destination = .new,
    /// Append `,S=<bytes>` to the delivered name, so that the size can be
    /// had from a directory listing rather than a `stat`.
    record_size: bool = true,
    /// Ask the filesystem to put the message on the disk before it is named
    /// in `new` or `cur`. Costs a round trip to the storage per delivery;
    /// without it a crash can leave a file that exists and is empty, which is
    /// worse than a message that never arrived.
    sync: bool = true,
};

fn deliverOptions(options: Options) maildir.Maildir.DeliverOptions {
    return .{
        .to = options.to,
        .record_size = options.record_size,
        .sync = options.sync,
    };
}

/// Streams an email into a notmuch database: the message is composed through
/// a `std.Io.Writer` into the mail store, then indexed.
///
/// The delivery itself is [zig-maildir](https://git.jcollie.dev/jeff/zig-maildir)'s
/// — notmuch indexes a maildir but does not write one — which means the whole
/// protocol rather than an approximation of it: the message is written into
/// the mail root's `tmp` under a name nothing else will invent, synced, and
/// renamed into `new` or `cur` once it is whole. A reader of the mail store
/// therefore never sees a partial message, and `cancel` removes the
/// half-written file without a trace.
///
/// The database's path must be a maildir — `tmp`, `new` and `cur` — or `init`
/// fails with `error.NotAMaildir` rather than delivering somewhere unsafe.
///
/// `buffer` is caller-owned and must remain valid until `finish` or `cancel`
/// is called. The `MessageWriter` must not be moved after `writer` has been
/// called, because what `writer` returns points into it.
pub const MessageWriter = struct {
    database: Database,
    /// The mail store, opened on the database's path and closed by `finish`
    /// or `cancel`.
    mailbox: maildir.Maildir,
    /// The message being written into `tmp`. Not a message in the mail store
    /// until it is committed.
    delivery: maildir.Maildir.Delivery,
    options: Options,
    io: std.Io,
    buffer: []u8,

    /// Prepare to stream an email into the database's mail store. Writes are
    /// buffered through `buffer`; nothing is written to the file until
    /// `writer` is called.
    pub fn init(io: std.Io, database: Database, buffer: []u8, options: Options) !MessageWriter {
        const root = database.getPath() orelse return error.NoDatabasePath;

        var mw: MessageWriter = .{
            .database = database,
            .mailbox = try maildir.Maildir.open(.cwd(), io, root, .{}),
            .delivery = undefined,
            .options = options,
            .io = io,
            .buffer = buffer,
        };
        errdefer mw.mailbox.close(io);

        mw.delivery = try mw.mailbox.beginDelivery(io, deliverOptions(options).attempts);
        return mw;
    }

    /// The `std.Io.Writer` to compose the email into.
    ///
    /// The returned pointer is invalidated by moving the `MessageWriter`, and
    /// by `finish` and `cancel`.
    pub fn writer(self: *MessageWriter) *std.Io.Writer {
        // The delivery keeps a pointer to the maildir it will be renamed
        // within, and both live in this struct, which the caller is free to
        // move until the writer below hands out a pointer into it.
        self.delivery.maildir = &self.mailbox;
        if (self.delivery.file_writer == null) return self.delivery.writer(self.io, self.buffer);
        return &self.delivery.file_writer.?.interface;
    }

    /// The name the message currently has in the mail store's `tmp`
    /// directory, which is also the identity — `maildir.Name.base` — of the
    /// name it is delivered under: committing the delivery appends the size
    /// and the maildir info part, and changes nothing before them.
    ///
    /// The returned slice points into the writer and is invalidated by
    /// `finish` and `cancel`; copy it if it is needed afterwards. After a
    /// successful `finish`, `Message.getFilename` on the returned message
    /// reports the full delivered path.
    pub fn tempName(self: *const MessageWriter) []const u8 {
        return self.delivery.tempName();
    }

    test tempName {
        const fixture = @import("testing.zig");

        var test_db = try fixture.corpusDatabase();
        defer test_db.deinit();

        // The temporary name leads with the delivery time, so names sort by
        // arrival, and ends with the host that wrote it.
        var mw = try test_db.newMessage(.{});
        try std.testing.expect(std.ascii.isDigit(mw.tempName()[0]));
        try std.testing.expect(std.mem.indexOf(u8, mw.tempName(), ".M") != null);

        var name_buf: maildir.Maildir.NameBuffer = undefined;
        const name = name_buf[0..mw.tempName().len];
        @memcpy(name, mw.tempName());

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
        const message = try mw.finish();
        defer message.deinit();

        // The delivered name is that one with the size appended: same
        // message, and the identity a maildir reader keys on is unchanged.
        const delivered = std.fs.path.basename(try message.getFilename());
        const parsed: maildir.Name = .parse(delivered, maildir.Name.default_separator);
        try std.testing.expectEqualStrings(name, parsed.base());
        try std.testing.expect(parsed.size() != null);
    }

    /// Flush the email, deliver it into the mail store, index it into the
    /// database, and return the indexed message. The caller owns the returned
    /// message. The database must be open in read-write mode.
    ///
    /// A failure before the delivery is committed leaves nothing behind; a
    /// failure to index one that has been leaves the message in the mail
    /// store, where the next `notmuch new` will find it.
    pub fn finish(self: *MessageWriter, indexopts: ?IndexOpts) !Message {
        const io = self.io;
        // The struct may have moved since init, so re-point the delivery at
        // the maildir it is being renamed within.
        self.delivery.maildir = &self.mailbox;
        defer {
            self.mailbox.close(io);
            self.* = undefined;
        }

        const delivered = try self.delivery.commit(io, deliverOptions(self.options));

        const root = self.database.getPath() orelse return error.NoDatabasePath;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}/{s}", .{
            root,
            delivered.subdir.dirname(),
            delivered.filename(),
        }, 0) catch return error.NameTooLong;
        return self.database.indexFileGetMessage(path, indexopts);
    }

    /// Discard the partially written email without delivering or indexing it.
    /// Nothing ever appears in `new` or `cur`, and the file in `tmp` is
    /// removed.
    pub fn cancel(self: *MessageWriter) void {
        const io = self.io;
        self.delivery.maildir = &self.mailbox;
        self.delivery.abort(io);
        self.mailbox.close(io);
        self.* = undefined;
    }

    test cancel {
        const fixture = @import("testing.zig");
        const io = std.testing.io;

        var test_db = try fixture.corpusDatabase();
        defer test_db.deinit();

        // A cancelled message leaves nothing behind — not in `new`, where it
        // was headed, and not in `tmp`, where it was written.
        var mw = try test_db.newMessage(.{ .to = .new });
        try mw.writer().writeAll("From: partial <partial@example.org>\n");
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "mail/tmp/{s}", .{mw.tempName()});
        mw.cancel();
        try std.testing.expectError(error.FileNotFound, test_db.tmp.dir.access(io, path, .{}));

        // Nothing arrived: `new` still holds exactly the corpus.
        var it = test_db.mailbox.iterate(.new);
        var count: usize = 0;
        while (try it.next(io)) |_| count += 1;
        try std.testing.expectEqual(fixture.corpus.len, count);
    }
};

test MessageWriter {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    // A finished message is delivered into new/ and indexed.
    var finished = try test_db.newMessage(.{ .to = .new });
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
    const message = try finished.finish();
    defer message.deinit();
    try std.testing.expectEqualStrings("seven@example.org", message.getMessageID() orelse "");
    try std.testing.expect(std.mem.indexOf(u8, try message.getFilename(), "/new/") != null);

    // Delivery into cur/ carries the maildir flags it was given.
    var seen = try test_db.newMessage(.{ .to = .{ .cur = .{ .seen = true } } });
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
    const seen_message = try seen.finish();
    defer seen_message.deinit();
    const seen_filename = try seen_message.getFilename();
    try std.testing.expect(std.mem.indexOf(u8, seen_filename, "/cur/") != null);
    try std.testing.expect(std.mem.endsWith(u8, seen_filename, ":2,S"));

    // ...which notmuch reads back as the flag it is.
    try std.testing.expect(try seen_message.hasMaildirFlag(.S));
}
