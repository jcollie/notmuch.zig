// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Iterator over a list of messages, as returned by `Query.searchMessages`,
//! `Thread.getMessages`, and `Message.getReplies`.
//!
//! `next` returns `Message` objects owned by the underlying query;
//! `collectTags` gathers the tags of all remaining messages instead. The
//! iterator is owned by the query it derived from; `deinit` releases it
//! sooner.
const MessagesIterator = @This();

const std = @import("std");

const c = @import("c");

const Message = @import("Message.zig");
const TagsIterator = @import("TagsIterator.zig");
const status = @import("enums.zig").status;

/// The underlying `notmuch_messages_t` handle, or `null` for an iterator
/// over an empty list.
messages: ?*c.notmuch_messages_t,

pub const NextError = error{
    /// Iteration failed to allocate memory.
    OutOfMemory,
    /// Iteration was invalidated by the database. Re-open the database and
    /// try again.
    OperationInvalidated,
    /// The item could not be built out of the database.
    ///
    /// `notmuch_messages_get` is documented to return NULL only for an
    /// out-of-memory situation, but the message is constructed on demand out
    /// of the database when it is asked for, so *any* failure to construct
    /// one arrives the same way -- a read invalidated by a writer committing
    /// underneath the search is how this was first seen, on a live archive
    /// taking mail while somebody read it.
    ///
    /// Reported as a Xapian exception rather than as `OutOfMemory`, which is
    /// what the header's wording would suggest, because the allocator is
    /// rarely the real cause and a caller that treats running out of memory
    /// as fatal would give up on something it should have retried. It is the
    /// same mapping `Directory` uses for a NULL return.
    XapianException,
    /// libnotmuch returned an undocumented status code.
    Unexpected,
};

/// Return a list of tags from all messages.
///
/// The resulting list is guaranteed not to contain duplicated tags.
///
/// WARNING: You can no longer iterate over messages after calling this
/// function, because the iterator will point at the end of the list. We do
/// not have a function to reset the iterator yet and the only way how you can
/// iterate over the list again is to recreate the message list.
///
/// The function returns `null` on error.
pub fn collectTags(self: *const MessagesIterator) ?TagsIterator {
    const messages = self.messages orelse return null;
    return .{
        .tags = c.notmuch_messages_collect_tags(messages) orelse return null,
    };
}

test collectTags {
    const fixture = @import("testing.zig");

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
    var messages = try query.searchMessages();
    defer messages.deinit();

    // The tags of all remaining messages, gathered in one pass. This
    // exhausts the message iterator, per the warning above.
    var collected = messages.collectTags() orelse return error.TestUnexpectedResult;
    defer collected.deinit();
    var saw_red = false;
    var saw_blue = false;
    while (collected.next()) |tag| {
        if (std.mem.eql(u8, tag, "red")) saw_red = true;
        if (std.mem.eql(u8, tag, "blue")) saw_blue = true;
    }
    try std.testing.expect(saw_red);
    try std.testing.expect(saw_blue);
    try std.testing.expect(try messages.next() == null);
}

pub fn next(self: *const MessagesIterator) NextError!?Message {
    const messages = self.messages orelse return null;
    return switch (status(c.notmuch_messages_status(messages))) {
        .success => message: {
            if (c.notmuch_messages_valid(messages) == 0) break :message null;
            defer c.notmuch_messages_move_to_next(messages);
            break :message .{
                .message = c.notmuch_messages_get(messages) orelse return error.XapianException,
            };
        },
        .iterator_exhausted => return null,
        .operation_invalidated => error.OperationInvalidated,
        .out_of_memory => error.OutOfMemory,
        else => error.Unexpected,
    };
}

test next {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const query = try test_db.database.queryCreate("*");
    defer query.deinit();
    var messages = try query.searchMessages();
    defer messages.deinit();

    // Iterate all matches; after exhaustion, next keeps returning null.
    var count: usize = 0;
    while (try messages.next()) |message| : (count += 1) message.deinit();
    try std.testing.expectEqual(fixture.corpus.len, count);
    try std.testing.expect(try messages.next() == null);
}

/// Deinitialize a `MessagesIterator` object.
///
/// It's not strictly necessary to call this function. All memory from
/// the `MessagesIterator` object will be reclaimed when the
/// containing query object is deinitialized.
pub fn deinit(self: *const MessagesIterator) void {
    const messages = self.messages orelse return;
    c.notmuch_messages_destroy(messages);
}
