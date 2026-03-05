// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Zig bindings for the Notmuch C API.
//!
const std = @import("std");

const c = @import("c");

pub const Database = @import("Database.zig");
pub const Error = @import("error.zig").Error;
pub const FilenamesIterator = @import("FilenamesIterator.zig");
pub const Message = @import("Message.zig");
pub const MessagesIterator = @import("MessagesIterator.zig");
pub const Query = @import("Query.zig");
pub const Thread = @import("Thread.zig");
pub const ThreadsIterator = @import("ThreadsIterator.zig");

/// The maximum length of a tag.
pub const tag_max: usize = @intCast(c.NOTMUCH_TAG_MAX);

const wrap = @import("error.zig").wrap;

/// Compact a `notmuch` database, backing up the original database to the given
/// path.
///
/// The database will be opened in read-write mode during the compaction process
/// to ensure no writes are made.
///
/// If the optional callback function `status_cb` is non-`null`, it will be
/// called with diagnostic and informational messages. The argument `closure` is
/// passed verbatim to any callback invoked.
pub fn compact(path: [:0]const u8, backup_path: [:0]const u8, status_cb: ?Database.StatusCallback, closure: ?*anyopaque) Error!void {
    try wrap(c.notmuch_database_compact_db(path, backup_path, status_cb, closure));
}

/// Interrogate the library for compile time features.
pub fn builtWith(name: [:0]const u8) bool {
    return c.notmuch_built_with(name) != 0;
}

test {
    std.testing.refAllDecls(@This());
}
