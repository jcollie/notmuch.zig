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

pub fn next(self: *TagsIterator) ?[:0]const u8 {
    const tags = self.tags orelse return null;
    if (c.notmuch_tags_valid(tags) == 0) return null;
    defer c.notmuch_tags_move_to_next(tags);
    return std.mem.span(c.notmuch_tags_get(tags) orelse unreachable);
}

pub fn deinit(self: *TagsIterator) void {
    c.notmuch_tags_destroy(self.tags);
}
