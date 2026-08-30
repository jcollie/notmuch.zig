// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Integration tests exercising the bindings against a real notmuch database
//! built from the embedded corpus in `testing.zig`.

const std = @import("std");

const notmuch = @import("notmuch.zig");
const fixture = @import("testing.zig");

const TagsIterator = @import("TagsIterator.zig");

/// Consume a tags iterator and report whether it yields `name`.
fn hasTag(tags: *TagsIterator, name: []const u8) bool {
    defer tags.deinit();
    while (tags.next()) |tag| {
        if (std.mem.eql(u8, tag, name)) return true;
    }
    return false;
}

/// Consume a tags iterator and count its entries.
fn countTags(tags: *TagsIterator) usize {
    defer tags.deinit();
    var n: usize = 0;
    while (tags.next()) |_| n += 1;
    return n;
}

test "Database.open on an existing database" {
    const alloc = std.testing.allocator;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    // Close the writer so its changes are committed and visible to readers.
    const path = try alloc.dupeZ(u8, test_db.database.getPath() orelse return error.TestUnexpectedResult);
    defer alloc.free(path);
    try test_db.database.close();

    const ro = switch (notmuch.Database.open(.read_only, .{
        .database_path = path,
        .config_path = "",
    })) {
        .ok => |db| db,
        .err => |e| {
            defer e.deinit();
            return e.err;
        },
    };
    defer ro.deinit() catch {};

    const query = try ro.queryCreate("*");
    defer query.deinit();
    try std.testing.expectEqual(@as(u32, fixture.corpus.len), try query.countMessages());
}

test "Database path, version, and upgrade status" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const path = db.getPath() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(u8, path, "mail"));
    try std.testing.expect(try db.getVersion() > 0);
    try std.testing.expect(!db.needsUpgrade());
    try db.upgrade(null, null);
}

test "Database.getVersion" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const version = try test_db.database.getVersion();
    try std.testing.expect(version > 0);

    // A closed database has no determinable version.
    try test_db.database.close();
    try std.testing.expectError(error.FormatVersionError, test_db.database.getVersion());
}

test "Database revisions increase with commits" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const before = db.getRevision();
    const message = try db.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try message.addTag("revision-test");
    const after = db.getRevision();

    try std.testing.expectEqualStrings(before.uuid, after.uuid);
    try std.testing.expect(try after.compare(before) == .gt);
}

test "Database atomic sections" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    try db.beginAtomic();
    const message = try db.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try message.addTag("atomic-test");
    try db.endAtomic();

    var tags = message.getTags();
    try std.testing.expect(hasTag(&tags, "atomic-test"));
}

test "Database.getDirectory and Directory" {
    const alloc = std.testing.allocator;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const root = db.getPath() orelse return error.TestUnexpectedResult;
    const cur_path = try std.fs.path.joinZ(alloc, &.{ root, "cur" });
    defer alloc.free(cur_path);

    const directory = try db.getDirectory(cur_path) orelse return error.TestUnexpectedResult;
    defer directory.deinit();

    try std.testing.expectEqual(@as(?i64, null), directory.getMtime());
    try directory.setMtime(12345);
    try std.testing.expectEqual(@as(?i64, 12345), directory.getMtime());

    var files = try directory.getChildFiles();
    defer files.deinit();
    var count: usize = 0;
    while (files.next()) |_| count += 1;
    try std.testing.expectEqual(fixture.corpus.len, count);

    var dirs = try directory.getChildDirectories();
    defer dirs.deinit();
    try std.testing.expectEqual(@as(?[:0]const u8, null), dirs.next());
}

test "Database message lookup and removal" {
    const alloc = std.testing.allocator;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    try std.testing.expectEqual(@as(?notmuch.Message, null), try db.findMessage("missing@example.org"));

    const root = db.getPath() orelse return error.TestUnexpectedResult;
    const path = try std.fs.path.joinZ(alloc, &.{ root, "cur", "three.eml" });
    defer alloc.free(path);

    const message = try db.findMessageByFilename(path) orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try std.testing.expectEqualStrings("three@example.org", message.getMessageID() orelse "");

    try db.removeMessage(path);
    try std.testing.expectEqual(@as(?notmuch.Message, null), try db.findMessage("three@example.org"));

    const query = try db.queryCreate("*");
    defer query.deinit();
    try std.testing.expectEqual(@as(u32, fixture.corpus.len - 1), try query.countMessages());
}

test "Database configuration access" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    try std.testing.expectEqualStrings(
        "zig@example.org",
        try db.configGet(.primary_email) orelse return error.TestUnexpectedResult,
    );

    try db.configSet(.user_name, "Test User");
    try std.testing.expectEqualStrings(
        "Test User",
        try db.configGet(.user_name) orelse return error.TestUnexpectedResult,
    );

    try std.testing.expect(try db.configGetBool(.sync_maildir_flags));

    const config_path = db.configPath() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(u8, config_path, "config"));

    var values = db.configGetValues(.new_tags) orelse return error.TestUnexpectedResult;
    defer values.deinit();
    var saw_unread = false;
    while (values.next()) |value| {
        if (std.mem.eql(u8, value, "unread")) saw_unread = true;
    }
    try std.testing.expect(saw_unread);

    var pairs = db.configGetPairs("") orelse return error.TestUnexpectedResult;
    defer pairs.deinit();
    var saw_pair = false;
    while (pairs.next()) |_| saw_pair = true;
    try std.testing.expect(saw_pair);
}

test "Database.getAllTags" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const message = try db.findMessage("four@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try message.addTag("zig");

    var tags = db.getAllTags() orelse return error.TestUnexpectedResult;
    try std.testing.expect(hasTag(&tags, "zig"));
}

test "Database.indexFileGetMessage and reopen" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    try test_db.tmp.dir.writeFile(io, .{
        .sub_path = "mail/cur/five.eml",
        .data =
        \\From: Erin <erin@example.org>
        \\To: Alice <alice@example.org>
        \\Subject: One more thing
        \\Date: Thu, 04 Apr 2024 10:00:00 +0000
        \\Message-ID: <five@example.org>
        \\
        \\Just one more thing.
        \\
        ,
    });

    const root = test_db.database.getPath() orelse return error.TestUnexpectedResult;
    const path = try std.fs.path.joinZ(alloc, &.{ root, "cur", "five.eml" });
    defer alloc.free(path);

    const message = try test_db.database.indexFileGetMessage(path, null);
    defer message.deinit();
    try std.testing.expectEqualStrings("five@example.org", message.getMessageID() orelse "");

    try test_db.database.reopen(.read_only);
    const query = try test_db.database.queryCreate("*");
    defer query.deinit();
    try std.testing.expectEqual(@as(u32, fixture.corpus.len + 1), try query.countMessages());
}

test "IndexOpts decrypt policy" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const indexopts = test_db.database.getDefaultIndexOpts() orelse return error.TestUnexpectedResult;
    defer indexopts.deinit();

    try indexopts.setDecryptPolicy(.true);
    try std.testing.expectEqual(notmuch.IndexOpts.Decrypt.true, indexopts.getDecryptPolicy());
}

test "Query string, sort, and database accessors" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("tag:inbox");
    defer query.deinit();

    try std.testing.expectEqualStrings("tag:inbox", query.getQueryString());
    query.setSort(.oldest_first);
    try std.testing.expectEqual(notmuch.Query.Sort.oldest_first, query.getSort());
    try std.testing.expect(query.getDatabase() != null);
}

test "Query search respects sort order" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("*");
    defer query.deinit();

    query.setSort(.oldest_first);
    var oldest = try query.searchMessages();
    defer oldest.deinit();
    const first = try oldest.next() orelse return error.TestUnexpectedResult;
    defer first.deinit();
    try std.testing.expectEqualStrings("Lunch plans", first.getHeader("Subject") orelse "");

    query.setSort(.newest_first);
    var newest = try query.searchMessages();
    defer newest.deinit();
    const last = try newest.next() orelse return error.TestUnexpectedResult;
    defer last.deinit();
    try std.testing.expectEqualStrings("Zig bindings", last.getHeader("Subject") orelse "");
}

test "Query search terms" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("from:carol@example.org");
    defer query.deinit();
    try std.testing.expectEqual(@as(u32, 1), try query.countMessages());
    try std.testing.expectEqual(@as(u32, 1), try query.countThreads());
}

test "Query tag exclusion" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const spam = try db.findMessage("three@example.org") orelse return error.TestUnexpectedResult;
    defer spam.deinit();
    try spam.addTag("spam");

    const query = try db.queryCreate("*");
    defer query.deinit();
    try query.addTagExclude("spam");
    query.setOmitExcluded(.true);

    var messages = try query.searchMessages();
    defer messages.deinit();
    var count: usize = 0;
    while (try messages.next()) |message| {
        defer message.deinit();
        count += 1;
    }
    try std.testing.expectEqual(fixture.corpus.len - 1, count);
}

test "Message identity, headers, and dates" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    try std.testing.expectEqualStrings("one@example.org", message.getMessageID() orelse "");
    try std.testing.expect(message.getThreadID() != null);
    // Mon, 01 Apr 2024 09:00:00 +0000
    try std.testing.expectEqual(@as(?i64, 1711962000), message.getDate());
    try std.testing.expectEqualStrings("Alice <alice@example.org>", message.getHeader("From") orelse "");
    try std.testing.expectEqualStrings("", message.getHeader("X-Nonexistent") orelse "missing");
}

test "Message filenames" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    try std.testing.expectEqual(@as(usize, 1), try message.countFiles());
    try std.testing.expect(std.mem.endsWith(u8, try message.getFilename(), "one.eml"));

    var filenames = try message.getFilenames();
    defer filenames.deinit();
    var count: usize = 0;
    while (filenames.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Message tag manipulation" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    try message.addTag("foo");
    try message.addTag("bar");
    var tags = message.getTags();
    try std.testing.expectEqual(@as(usize, 2), countTags(&tags));

    try message.removeTag("foo");
    tags = message.getTags();
    try std.testing.expect(!hasTag(&tags, "foo"));
    tags = message.getTags();
    try std.testing.expect(hasTag(&tags, "bar"));

    try message.removeAllTags();
    tags = message.getTags();
    try std.testing.expectEqual(@as(usize, 0), countTags(&tags));
}

test "Message freeze and thaw" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const message = try test_db.database.findMessage("two@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    try message.freeze();
    try message.addTag("frozen");
    try message.thaw();

    var tags = message.getTags();
    try std.testing.expect(hasTag(&tags, "frozen"));
}

test "Message properties" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    try message.addProperty("test.key", "value1");
    try message.addProperty("test.key", "value2");
    try std.testing.expectEqualStrings(
        "value1",
        message.getProperty("test.key") orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqual(@as(usize, 2), try message.countProperties("test.key"));

    var properties = message.getProperties("test.key", true);
    defer properties.deinit();
    var count: usize = 0;
    while (properties.next()) |kv| {
        try std.testing.expectEqualStrings("test.key", kv.key);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);

    try message.removeProperty("test.key", "value1");
    try std.testing.expectEqual(@as(usize, 1), try message.countProperties("test.key"));

    try message.removeAllProperties(null);
    try std.testing.expectEqual(@as(usize, 0), try message.countProperties("test.key"));
}

test "Message flags" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    try std.testing.expect(!try message.getFlag(.ghost));
    message.setFlag(.match, true);
    try std.testing.expect(try message.getFlag(.match));
}

test "Message maildir flags" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    // The corpus filenames carry no ":2," maildir info part.
    try std.testing.expect(!try message.hasMaildirFlag(.S));
    try std.testing.expect(!try message.hasMaildirFlag(.F));
    try message.maildirFlagsToTags();
}

test "Thread accessors" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("subject:lunch");
    defer query.deinit();
    query.setSort(.oldest_first);

    var threads = try query.searchThreads();
    defer threads.deinit();
    const thread = try threads.next() orelse return error.TestUnexpectedResult;
    defer thread.deinit();

    try std.testing.expectEqualStrings("Lunch plans", thread.getSubject());
    try std.testing.expectEqual(@as(usize, 2), thread.getTotalMessages());
    try std.testing.expectEqual(@as(usize, 2), thread.getTotalFiles());
    try std.testing.expectEqual(@as(usize, 2), thread.getMatchedMessages());
    try std.testing.expect(std.mem.indexOf(u8, thread.getAuthors(), "Alice") != null);
    // Mon, 01 Apr 2024 09:00:00 +0000 through 09:30:00
    try std.testing.expectEqual(@as(i64, 1711962000), thread.getOldestDate());
    try std.testing.expectEqual(@as(i64, 1711963800), thread.getNewestDate());
    try std.testing.expectEqual(@as(?notmuch.Thread, null), try threads.next());
}

test "Thread message traversal" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("subject:lunch");
    defer query.deinit();

    var threads = try query.searchThreads();
    defer threads.deinit();
    const thread = try threads.next() orelse return error.TestUnexpectedResult;
    defer thread.deinit();

    var toplevel = thread.getToplevelMessages();
    const top = try toplevel.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("one@example.org", top.getMessageID() orelse "");
    try std.testing.expectEqualStrings(
        thread.getThreadID(),
        top.getThreadID() orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqual(@as(?notmuch.Message, null), try toplevel.next());

    var replies = top.getReplies();
    const reply = try replies.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("two@example.org", reply.getMessageID() orelse "");

    var all = thread.getMessages();
    var count: usize = 0;
    while (try all.next()) |message| count += @intFromBool(message.getMessageID() != null);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Thread and MessagesIterator tag collection" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const one = try db.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer one.deinit();
    try one.addTag("red");
    const two = try db.findMessage("two@example.org") orelse return error.TestUnexpectedResult;
    defer two.deinit();
    try two.addTag("blue");

    const query = try db.queryCreate("subject:lunch");
    defer query.deinit();

    var threads = try query.searchThreads();
    defer threads.deinit();
    const thread = try threads.next() orelse return error.TestUnexpectedResult;
    defer thread.deinit();

    var thread_tags = thread.getTags();
    try std.testing.expect(hasTag(&thread_tags, "red"));

    var messages = try query.searchMessages();
    defer messages.deinit();
    var collected = messages.collectTags() orelse return error.TestUnexpectedResult;
    try std.testing.expect(hasTag(&collected, "blue"));
}

test "Database.open error reporting" {
    const missing = notmuch.Database.open(.read_only, .{
        .database_path = "/nonexistent/notmuch-zig-test",
        .config_path = "",
    });
    switch (missing) {
        .ok => |db| {
            db.deinit() catch {};
            return error.TestUnexpectedResult;
        },
        .err => |e| {
            defer e.deinit();
            try std.testing.expectEqual(notmuch.Database.OpenError.NoDatabase, e.err);
        },
    }

    const relative = notmuch.Database.open(.read_only, .{
        .database_path = "relative/path",
        .config_path = "",
    });
    switch (relative) {
        .ok => |db| {
            db.deinit() catch {};
            return error.TestUnexpectedResult;
        },
        .err => |e| {
            defer e.deinit();
            try std.testing.expectEqual(notmuch.Database.OpenError.PathError, e.err);
        },
    }
}

test "writes to a read-only database return errors" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    try test_db.database.reopen(.read_only);

    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    try std.testing.expectError(error.ReadOnlyDatabase, message.addTag("probe"));
    try std.testing.expectError(error.ReadOnlyDatabase, message.addProperty("probe.key", "value"));
    try std.testing.expectError(error.ReadOnlyDatabase, message.removeProperty("probe.key", "value"));
    try std.testing.expectError(error.ReadOnlyDatabase, message.removeAllProperties(null));
}

test "module helpers" {
    try std.testing.expect(notmuch.builtWith("compact"));
    try std.testing.expect(!notmuch.builtWith("time-travel"));
    try std.testing.expect(notmuch.tag_max > 0);
}
