// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Iterator over a list of filenames, as returned by `Message.getFilenames`
//! and the `Directory` child listings.
//!
//! The strings returned by `next` are owned by the iterator's parent object.
//! The iterator itself is owned by the object it came from; `deinit` releases
//! it sooner.
pub const FilenamesIterator = @This();

const std = @import("std");
const c = @import("c");

/// The underlying `notmuch_filenames_t` handle, or `null` for an iterator
/// over an empty list.
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

test next {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    // The corpus message is backed by a single file; after exhaustion,
    // next keeps returning null.
    var filenames = try message.getFilenames();
    defer filenames.deinit();
    const filename = filenames.next() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(u8, filename, "one.eml"));
    try std.testing.expect(filenames.next() == null);
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
