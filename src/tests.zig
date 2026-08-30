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

test "Database revisions are monotonic across commits" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const message = try db.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    var previous = db.getRevision();
    for ([_][:0]const u8{ "mono-one", "mono-two", "mono-three" }) |tag| {
        try message.addTag(tag);
        const current = db.getRevision();
        try std.testing.expect(try current.compare(previous) == .gt);
        previous = current;
    }
}

test "Database UUIDs are unique per database" {
    var test_db1 = try fixture.corpusDatabase();
    defer test_db1.deinit();
    var test_db2 = try fixture.corpusDatabase();
    defer test_db2.deinit();

    const rev1 = test_db1.database.getRevision();
    const rev2 = test_db2.database.getRevision();

    try std.testing.expect(!std.mem.eql(u8, rev1.uuid, rev2.uuid));
    try std.testing.expectError(error.DatabaseMismatch, rev1.compare(rev2));
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

test "Database atomic section error paths" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // endAtomic without a matching beginAtomic is unbalanced.
    try std.testing.expectError(error.UnbalancedAtomic, db.endAtomic());

    // Atomic sections nest; the extra endAtomic is unbalanced again.
    try db.beginAtomic();
    try db.beginAtomic();
    try db.endAtomic();
    try db.endAtomic();
    try std.testing.expectError(error.UnbalancedAtomic, db.endAtomic());

    // On a read-only database notmuch does not open a Xapian transaction, so
    // a balanced pair still succeeds.
    try test_db.database.reopen(.read_only);
    try db.beginAtomic();
    try db.endAtomic();
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

test "Database.removeMessage with a message stored under multiple filenames" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // Index a second file carrying the same Message-ID as one.eml.
    try test_db.tmp.dir.writeFile(io, .{
        .sub_path = "mail/cur/one-copy.eml",
        .data = fixture.corpus[0].data,
    });

    const root = db.getPath() orelse return error.TestUnexpectedResult;
    const original = try std.fs.path.joinZ(alloc, &.{ root, "cur", "one.eml" });
    defer alloc.free(original);
    const copy = try std.fs.path.joinZ(alloc, &.{ root, "cur", "one-copy.eml" });
    defer alloc.free(copy);

    try db.indexFile(copy, null);

    const message = try db.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try std.testing.expectEqual(@as(usize, 2), try message.countFiles());

    // Removing one filename reports DuplicateMessageID: the filename is gone
    // but the message persists under the remaining filename.
    try std.testing.expectError(error.DuplicateMessageID, db.removeMessage(original));
    const remaining = try db.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer remaining.deinit();
    try std.testing.expectEqual(@as(usize, 1), try remaining.countFiles());
    try std.testing.expect(std.mem.endsWith(u8, try remaining.getFilename(), "one-copy.eml"));

    // Removing the last filename removes the message content. Because
    // two@example.org references this message ID, notmuch keeps it as a
    // "ghost": findable, but with no files.
    try db.removeMessage(copy);
    const ghost = try db.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer ghost.deinit();
    try std.testing.expect(try ghost.getFlag(.ghost));
}

test "Database.findMessageByFilename" {
    const alloc = std.testing.allocator;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const root = db.getPath() orelse return error.TestUnexpectedResult;

    // Lookup by absolute filename.
    const abs = try std.fs.path.joinZ(alloc, &.{ root, "cur", "two.eml" });
    defer alloc.free(abs);
    const by_abs = try db.findMessageByFilename(abs) orelse return error.TestUnexpectedResult;
    defer by_abs.deinit();
    try std.testing.expectEqualStrings("two@example.org", by_abs.getMessageID() orelse "");

    // Lookup by filename relative to the database path.
    const by_rel = try db.findMessageByFilename("cur/two.eml") orelse return error.TestUnexpectedResult;
    defer by_rel.deinit();
    try std.testing.expectEqualStrings("two@example.org", by_rel.getMessageID() orelse "");

    // Unknown filenames return null.
    try std.testing.expectEqual(@as(?notmuch.Message, null), try db.findMessageByFilename("cur/missing.eml"));

    // A closed database reports a Xapian exception.
    try db.close();
    try std.testing.expectError(error.XapianException, db.findMessageByFilename(abs));
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

test "Database configGet and configSet" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // A value from the configuration file.
    try std.testing.expectEqualStrings(
        "zig@example.org",
        try db.configGet(.primary_email) orelse return error.TestUnexpectedResult,
    );

    // Round-trip through the database, including overwriting.
    try db.configSet(.user_name, "Test User");
    try std.testing.expectEqualStrings(
        "Test User",
        try db.configGet(.user_name) orelse return error.TestUnexpectedResult,
    );
    try db.configSet(.user_name, "Renamed User");
    try std.testing.expectEqualStrings(
        "Renamed User",
        try db.configGet(.user_name) orelse return error.TestUnexpectedResult,
    );

    // Values set through configSet persist across close and reopen.
    try db.close();
    try test_db.database.reopen(.read_write);
    try std.testing.expectEqualStrings(
        "Renamed User",
        try db.configGet(.user_name) orelse return error.TestUnexpectedResult,
    );

    // configGetBool rejects values that are not booleans.
    try std.testing.expectError(error.IllegalArgument, db.configGetBool(.primary_email));

    // configSet requires a read-write database.
    try test_db.database.reopen(.read_only);
    try std.testing.expectError(error.ReadOnlyDatabase, db.configSet(.user_name, "nope"));
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

test "Database.reopen switches modes" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    // After reopening read-only, writes fail.
    try test_db.database.reopen(.read_only);
    const ro_message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer ro_message.deinit();
    try std.testing.expectError(error.ReadOnlyDatabase, ro_message.addTag("nope"));

    // After reopening read-write, writes succeed again.
    try test_db.database.reopen(.read_write);
    const rw_message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer rw_message.deinit();
    try rw_message.addTag("reopened");
    var tags = rw_message.getTags();
    try std.testing.expect(hasTag(&tags, "reopened"));
}

test "Database.reopen picks up committed changes" {
    const alloc = std.testing.allocator;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const path = try alloc.dupeZ(u8, test_db.database.getPath() orelse return error.TestUnexpectedResult);
    defer alloc.free(path);

    // A second, read-only connection to the same database.
    var reader = switch (notmuch.Database.open(.read_only, .{
        .database_path = path,
        .config_path = "",
    })) {
        .ok => |db| db,
        .err => |e| {
            defer e.deinit();
            return e.err;
        },
    };
    defer reader.deinit() catch {};

    {
        const query = try reader.queryCreate("tag:fresh");
        defer query.deinit();
        try std.testing.expectEqual(@as(u32, 0), try query.countMessages());
    }

    // The writer tags a message and commits by closing.
    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try message.addTag("fresh");
    try test_db.database.close();

    // The reader sees the change only after reopening.
    try reader.reopen(.read_only);
    const query = try reader.queryCreate("tag:fresh");
    defer query.deinit();
    try std.testing.expectEqual(@as(u32, 1), try query.countMessages());
}

test "Database.reopen revives a closed database" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    try test_db.database.close();
    try std.testing.expectError(error.XapianException, test_db.database.findMessage("one@example.org"));

    // reopen brings a closed database back into a usable state.
    try test_db.database.reopen(.read_only);
    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try std.testing.expectEqualStrings("one@example.org", message.getMessageID() orelse "");
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

test "Query tag exclusion error paths" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("tag:spam");
    defer query.deinit();

    // Excluding a tag that appears explicitly in the query is ignored.
    try std.testing.expectError(error.Ignored, query.addTagExclude("spam"));

    // Other tags can still be excluded.
    try query.addTagExclude("other");
}

test "Query search error paths" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // Xapian-syntax queries are lenient: a malformed string is treated as
    // literal terms and still searches successfully.
    const lenient = try db.queryCreate("tag:(unbalanced");
    defer lenient.deinit();
    _ = try lenient.countMessages();

    // S-expression queries defer parsing until the query runs, so a bad
    // sexp errors at search/count time.
    const bad = try db.queryCreateWithSyntax("(unbalanced", .sexp);
    defer bad.deinit();
    try std.testing.expectError(error.BadQuerySyntax, bad.countMessages());
    try std.testing.expectError(error.BadQuerySyntax, bad.countThreads());
    try std.testing.expectError(error.BadQuerySyntax, bad.searchMessages());
    try std.testing.expectError(error.BadQuerySyntax, bad.searchThreads());
}

test "Query searches on a closed database" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("*");
    defer query.deinit();
    try test_db.database.close();

    try std.testing.expectError(error.XapianException, query.countMessages());
    try std.testing.expectError(error.XapianException, query.searchMessages());
    try std.testing.expectError(error.XapianException, query.searchThreads());
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

test "Message freeze and thaw error paths" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    // thaw without a matching freeze is unbalanced.
    try std.testing.expectError(error.UnbalancedFreezeThaw, message.thaw());

    // freeze/thaw calls stack; the extra thaw is unbalanced again.
    try message.freeze();
    try message.freeze();
    try message.thaw();
    try message.thaw();
    try std.testing.expectError(error.UnbalancedFreezeThaw, message.thaw());

    // freeze requires a read-write database.
    try test_db.database.reopen(.read_only);
    const ro_message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer ro_message.deinit();
    try std.testing.expectError(error.ReadOnlyDatabase, ro_message.freeze());
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

test "Message property error paths" {
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    // Property keys may not contain an '=' character.
    try std.testing.expectError(error.IllegalArgument, message.addProperty("bad=key", "value"));
    try std.testing.expectError(error.IllegalArgument, message.removeProperty("bad=key", "value"));

    // The remove-all variants require a read-write database.
    try test_db.database.reopen(.read_only);
    const ro_message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer ro_message.deinit();
    try std.testing.expectError(error.ReadOnlyDatabase, ro_message.removeAllProperties("test.key"));
    try std.testing.expectError(error.ReadOnlyDatabase, ro_message.removeAllPropertiesWithPrefix("test."));
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

test "Message.maildirFlagsToTags" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // A maildir file with the "flagged" flag set but not "seen".
    try test_db.tmp.dir.writeFile(io, .{
        .sub_path = "mail/cur/five:2,F",
        .data =
        \\From: Erin <erin@example.org>
        \\To: Alice <alice@example.org>
        \\Subject: Flagged mail
        \\Date: Thu, 04 Apr 2024 10:00:00 +0000
        \\Message-ID: <five@example.org>
        \\
        \\This one is flagged.
        \\
        ,
    });

    const root = db.getPath() orelse return error.TestUnexpectedResult;
    const path = try std.fs.path.joinZ(alloc, &.{ root, "cur", "five:2,F" });
    defer alloc.free(path);
    const message = try db.indexFileGetMessage(path, null);
    defer message.deinit();

    try std.testing.expect(try message.hasMaildirFlag(.F));
    try std.testing.expect(!try message.hasMaildirFlag(.S));
    try std.testing.expect(!try message.hasMaildirFlag(.D));

    try message.maildirFlagsToTags();

    // F present adds "flagged"; S absent performs the opposite of removing
    // "unread", i.e. adds it.
    var tags = message.getTags();
    try std.testing.expect(hasTag(&tags, "flagged"));
    tags = message.getTags();
    try std.testing.expect(hasTag(&tags, "unread"));
}

test "Message.tagsToMaildirFlags renames the file" {
    const io = std.testing.io;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const message = try db.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    try message.addTag("flagged");
    try message.addTag("passed");
    // No "unread" tag, so the seen flag is set as well.
    try message.tagsToMaildirFlags();

    const filename = try message.getFilename();
    try std.testing.expect(std.mem.endsWith(u8, filename, "one.eml:2,FPS"));
    try std.testing.expect(try message.hasMaildirFlag(.F));
    try std.testing.expect(try message.hasMaildirFlag(.P));
    try std.testing.expect(try message.hasMaildirFlag(.S));

    // The file was renamed on disk, not copied.
    try test_db.tmp.dir.access(io, "mail/cur/one.eml:2,FPS", .{});
    try std.testing.expectError(error.FileNotFound, test_db.tmp.dir.access(io, "mail/cur/one.eml", .{}));
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
