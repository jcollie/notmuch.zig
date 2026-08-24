// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! A Zig wrapper around the `notmuch` C APIs for dealing with
//! lists of filenames.
pub const FilenamesIterator = @This();

const std = @import("std");
const c = @import("c");

filenames: ?*c.notmuch_filenames_t,

/// Get the next filename from `FilenamesIterator` as a string.
///
/// Note: The returned string belongs to `filenames` and has a lifetime
/// identical to it (and the object to which it ultimately belongs).
pub fn next(self: *FilenamesIterator) ?[:0]const u8 {
    const filenames = self.filenames orelse return null;
    if (c.notmuch_filenames_valid(filenames) == 0) return null;
    defer c.notmuch_filenames_move_to_next(filenames);
    return std.mem.span(c.notmuch_filenames_get(filenames) orelse unreachable);
}

/// Deinitialize a `FilenamesIterator` object.
///
/// It's not strictly necessary to call this function. All memory from the
/// `FilenamesIterator` object will be reclaimed when the containing object
/// is deinitialized.
pub fn deinit(self: *FilenamesIterator) void {
    const filenames = self.filenames orelse return;
    c.notmuch_filenames_destroy(filenames);
}
