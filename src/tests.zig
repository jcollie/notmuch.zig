// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Integration tests exercising the bindings against a real notmuch database
//! built from the embedded corpus in `testing.zig`.

const std = @import("std");

const notmuch = @import("notmuch.zig");
const fixture = @import("testing.zig");

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
    try std.testing.expect(fixture.hasTag(&tags, "reopened"));
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
    try std.testing.expect(fixture.hasTag(&thread_tags, "red"));

    var messages = try query.searchMessages();
    defer messages.deinit();
    var collected = messages.collectTags() orelse return error.TestUnexpectedResult;
    try std.testing.expect(fixture.hasTag(&collected, "blue"));
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
