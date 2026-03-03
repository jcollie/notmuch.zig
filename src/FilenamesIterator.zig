// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! A Zig wrapper around the `notmuch` C APIs for dealing with
//! lists of filenames.
pub const FilenamesIterator = @This();

const c = @import("c");

const status = @import("enums.zig").status;

filenames: ?*c.notmuch_filenames_t,

pub const NextError = error{
    /// Iteration failed to allocate memory.
    OutOfMemory,
    /// Iteration was invalidated by the database. Re-open the database and
    /// try again.
    OperationInvalidated,
};

pub fn next(self: *FilenamesIterator) NextError!?[:0]const u8 {
    const threads = self.threads orelse return null;
    return switch (status(c.notmuch_threads_status(threads))) {
        .success => thread: {
            if (c.notmuch_threads_valid(threads) != 0) break :thread null;
            defer c.notmuch_threads_move_to_next(threads);
            break :thread .{
                .thread = c.notmuch_threads_get(threads) orelse unreachable,
            };
        },
        .iterator_exhausted => return null,
        .operation_invalidated => error.OperationInvalidated,
        .out_of_memory => error.OutOfMemory,
        else => unreachable,
    };
}

/// Deinitialize a `ThreadIterator` object.
///
/// It's not strictly necessary to call this function. All memory from
/// the `ThreadIterator` object will be reclaimed when the
/// containing query object is deinitialized.
pub fn deinit(self: *FilenamesIterator) void {
    const threads = self.threads orelse return;
    c.notmuch_threads_destroy(threads);
}
