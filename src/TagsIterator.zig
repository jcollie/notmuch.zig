// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Iterator over a list of tags, as returned by `Message.getTags`,
//! `Thread.getTags`, `Database.getAllTags`, and
//! `MessagesIterator.collectTags`.
//!
//! The iterator is owned by the object it came from; `deinit` releases it
//! sooner.
const TagsIterator = @This();

const std = @import("std");

const c = @import("c");

/// The underlying `notmuch_tags_t` handle, or `null` for an iterator over
/// an empty list.
tags: ?*c.notmuch_tags_t,

/// Get the next tag, or `null` if there are no more tags.
///
/// The returned string belongs to the tags object and has a lifetime
/// identical to it (and the object to which it ultimately belongs). It must
/// not be modified or freed by the caller.
pub fn next(self: *TagsIterator) ?[:0]const u8 {
    const tags = self.tags orelse return null;
    if (c.notmuch_tags_valid(tags) == 0) return null;
    defer c.notmuch_tags_move_to_next(tags);
    return std.mem.span(c.notmuch_tags_get(tags) orelse unreachable);
}

test next {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try message.addTag("beta");
    try message.addTag("alpha");

    // Tags are iterated in sorted order, regardless of insertion order;
    // after exhaustion, next keeps returning null.
    var tags = message.getTags();
    defer tags.deinit();
    try std.testing.expectEqualStrings("alpha", tags.next() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("beta", tags.next() orelse return error.TestUnexpectedResult);
    try std.testing.expect(tags.next() == null);
}

pub fn deinit(self: *TagsIterator) void {
    c.notmuch_tags_destroy(self.tags);
}
