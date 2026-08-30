// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! A thread of messages matching a search, as returned by
//! `Query.searchThreads`.
//!
//! Exposes the thread's subject, authors, dates, and message and file
//! counts, plus traversal of its messages via `getToplevelMessages` and
//! `getMessages`. The thread is owned by the query it derived from; `deinit`
//! releases it sooner.
const Thread = @This();

const std = @import("std");

const c = @import("c");

const Error = @import("error.zig").Error;
const wrap = @import("error.zig").wrap;

const MessagesIterator = @import("MessagesIterator.zig");
const TagsIterator = @import("TagsIterator.zig");

/// The underlying `notmuch_thread_t` handle; only needed directly when
/// calling libnotmuch C APIs these bindings do not wrap.
thread: *c.notmuch_thread_t,

/// Get the thread ID of `thread`.
///
/// The returned string belongs to `Thread` and as such, should not be modified
/// by the caller and will only be valid for as long as the thread is valid,
/// (which is until `deinit` is called or until the query from which it derived
/// is deinitialized).
pub fn getThreadID(self: *const Thread) [:0]const u8 {
    return std.mem.span(c.notmuch_thread_get_thread_id(self.thread));
}

test getThreadID {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("subject:lunch");
    defer query.deinit();
    var threads = try query.searchThreads();
    defer threads.deinit();
    const thread = try threads.next() orelse return error.TestUnexpectedResult;
    defer thread.deinit();

    // The thread's ID matches the thread ID of its messages.
    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try std.testing.expectEqualStrings(
        thread.getThreadID(),
        message.getThreadID() orelse return error.TestUnexpectedResult,
    );
}

/// Get the total number of messages in `Thread`.
///
/// This count consists of all messages in the database belonging to this
/// thread. Contrast with `getMatchedMessages`.
pub fn getTotalMessages(self: *const Thread) usize {
    std.debug.assert(@typeInfo(c_int).int.bits <= @typeInfo(usize).int.bits);
    return @intCast(@max(0, c.notmuch_thread_get_total_messages(self.thread)));
}

test getTotalMessages {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("subject:lunch");
    defer query.deinit();
    var threads = try query.searchThreads();
    defer threads.deinit();
    const thread = try threads.next() orelse return error.TestUnexpectedResult;
    defer thread.deinit();

    // The lunch thread holds the original message and its reply.
    try std.testing.expectEqual(@as(usize, 2), thread.getTotalMessages());
}

/// Get the total number of files in 'thread'.
///
/// This sums Message.countFiles over all messages in the thread.
pub fn getTotalFiles(self: *const Thread) usize {
    std.debug.assert(@typeInfo(c_int).int.bits <= @typeInfo(usize).int.bits);
    return @intCast(@max(0, c.notmuch_thread_get_total_files(self.thread)));
}

test getTotalFiles {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("subject:lunch");
    defer query.deinit();
    var threads = try query.searchThreads();
    defer threads.deinit();
    const thread = try threads.next() orelse return error.TestUnexpectedResult;
    defer thread.deinit();

    // Each corpus message is backed by one file.
    try std.testing.expectEqual(@as(usize, 2), thread.getTotalFiles());
}

/// Get a `MessagesIterator` for the top-level messages in `thread` in
/// oldest-first order.
///
/// This iterator will not necessarily iterate over all of the messages in the
/// thread. It will only iterate over the messages in the thread which are not
/// replies to other messages in the thread.
///
/// The returned list will be deinitialized when the thread is deinitialized.
pub fn getToplevelMessages(self: *const Thread) MessagesIterator {
    return .{
        .messages = c.notmuch_thread_get_toplevel_messages(self.thread),
    };
}

test getToplevelMessages {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("subject:lunch");
    defer query.deinit();
    var threads = try query.searchThreads();
    defer threads.deinit();
    const thread = try threads.next() orelse return error.TestUnexpectedResult;
    defer thread.deinit();

    // Only the message that started the thread is top-level; replies hang
    // off it via `Message.getReplies`.
    var toplevel = thread.getToplevelMessages();
    const top = try toplevel.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("one@example.org", top.getMessageID() orelse "");
    try std.testing.expect(try toplevel.next() == null);
}

/// Get a `MessagesIterator` for all messages in `Thread` in oldest-first order.
///
/// The returned list will be deinitialized when the thread is deinitialized.
pub fn getMessages(self: *const Thread) MessagesIterator {
    return .{
        .messages = c.notmuch_thread_get_messages(self.thread),
    };
}

test getMessages {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("subject:lunch");
    defer query.deinit();
    var threads = try query.searchThreads();
    defer threads.deinit();
    const thread = try threads.next() orelse return error.TestUnexpectedResult;
    defer thread.deinit();

    // All messages in the thread, in oldest-first order.
    var messages = thread.getMessages();
    const first = try messages.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("one@example.org", first.getMessageID() orelse "");
    const second = try messages.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("two@example.org", second.getMessageID() orelse "");
    try std.testing.expect(try messages.next() == null);
}

/// Get the number of messages in `Thread` that matched the search.
///
/// This count includes only the messages in this thread that were matched by
/// the search from which the thread was created and were not excluded by any
/// exclude tags passed in with the query (see `Query.addTagExclude`). Contrast
/// with `getTotalMessages`.
pub fn getMatchedMessages(self: *const Thread) usize {
    std.debug.assert(@typeInfo(c_int).int.bits <= @typeInfo(usize).int.bits);
    return @intCast(@max(0, c.notmuch_thread_get_matched_messages(self.thread)));
}

test getMatchedMessages {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    // Only Alice's half of the lunch thread matches this search, so one of
    // the thread's two messages is a match.
    const query = try test_db.database.queryCreate("from:alice@example.org");
    defer query.deinit();
    var threads = try query.searchThreads();
    defer threads.deinit();
    const thread = try threads.next() orelse return error.TestUnexpectedResult;
    defer thread.deinit();

    try std.testing.expectEqual(@as(usize, 2), thread.getTotalMessages());
    try std.testing.expectEqual(@as(usize, 1), thread.getMatchedMessages());
}

/// Get the authors of `Thread` as a UTF-8 string.
///
/// The returned string is a comma-separated list of the names of the authors of
/// mail messages in the query results that belong to this thread.
///
/// The string contains authors of messages matching the query first, then
/// non-matched authors (with the two groups separated by `|`). Within each
/// group, authors are ordered by date.
///
/// The returned string belongs to `Thread` and as such, should not be modified
/// by the caller and will only be valid for as long as the thread is valid,
/// (which is until `deinit` is called or until the query from which it derived
/// is deinitialized).
///
/// TODO: Create an iterator object that makes dealing with this list easier.
pub fn getAuthors(self: *const Thread) [:0]const u8 {
    return std.mem.span(c.notmuch_thread_get_authors(self.thread));
}

test getAuthors {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("subject:lunch");
    defer query.deinit();
    var threads = try query.searchThreads();
    defer threads.deinit();
    const thread = try threads.next() orelse return error.TestUnexpectedResult;
    defer thread.deinit();

    // Both participants matched the search, so both are listed.
    try std.testing.expectEqualStrings("Alice, Bob", thread.getAuthors());
}

/// Get the subject of `Thread` as a UTF-8 string.
///
/// The subject is taken from the first message (according to the query
/// order—see `Query.setSort`) in the query results that belongs to this thread.
///
/// The returned string belongs to `Thread` and as such, should not be modified
/// by the caller and will only be valid for as long as the thread is valid,
/// which is until `deinit` is called or until the query from which it derived
/// is deinitialized.
pub fn getSubject(self: *const Thread) [:0]const u8 {
    return std.mem.span(c.notmuch_thread_get_subject(self.thread));
}

test getSubject {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("subject:lunch");
    defer query.deinit();
    var threads = try query.searchThreads();
    defer threads.deinit();
    const thread = try threads.next() orelse return error.TestUnexpectedResult;
    defer thread.deinit();

    try std.testing.expectEqualStrings("Lunch plans", thread.getSubject());
}

/// Get the date of the oldest message in `Thread` as the number of seconds
/// since the Unix epoch (1970-01-01 00:00:00 UTC).
pub fn getOldestDate(self: *const Thread) i64 {
    std.debug.assert(@typeInfo(c_long).int.bits <= @typeInfo(i64).int.bits);
    return c.notmuch_thread_get_oldest_date(self.thread);
}

test getOldestDate {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("subject:lunch");
    defer query.deinit();
    var threads = try query.searchThreads();
    defer threads.deinit();
    const thread = try threads.next() orelse return error.TestUnexpectedResult;
    defer thread.deinit();

    // Mon, 01 Apr 2024 09:00:00 +0000: the date of the first message.
    try std.testing.expectEqual(@as(i64, 1711962000), thread.getOldestDate());
}

/// Get the date of the newest message in `Thread` as the number of seconds
/// since the Unix epoch (1970-01-01 00:00:00 UTC).
pub fn getNewestDate(self: *const Thread) i64 {
    std.debug.assert(@typeInfo(c_long).int.bits <= @typeInfo(i64).int.bits);
    return c.notmuch_thread_get_newest_date(self.thread);
}

test getNewestDate {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("subject:lunch");
    defer query.deinit();
    var threads = try query.searchThreads();
    defer threads.deinit();
    const thread = try threads.next() orelse return error.TestUnexpectedResult;
    defer thread.deinit();

    // Mon, 01 Apr 2024 09:30:00 +0000: the date of the reply.
    try std.testing.expectEqual(@as(i64, 1711963800), thread.getNewestDate());
}

/// Get the tags for `Thread`, returning a `TagsIterator` object which can be
/// used to iterate over all tags.
///
/// Note: In the `notmuch` database, tags are stored on individual messages, not
/// on threads. So the tags returned here will be all tags of the messages which
/// matched the search and which belong to this thread.
///
/// The tags object is owned by the thread and as such, will only be valid for
/// as long as the thread is valid, which is until `deinit` is called or until
/// the query from which it derived is destroyed.
pub fn getTags(self: *const Thread) TagsIterator {
    return .{
        .tags = c.notmuch_thread_get_tags(self.thread),
    };
}

test getTags {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // Tag the two thread members differently; the thread's tags are the
    // union of its messages' tags.
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

    var tags = thread.getTags();
    try std.testing.expect(fixture.hasTag(&tags, "red"));
    tags = thread.getTags();
    try std.testing.expect(fixture.hasTag(&tags, "blue"));
}

pub fn deinit(self: *const Thread) void {
    c.notmuch_thread_destroy(self.thread);
}
