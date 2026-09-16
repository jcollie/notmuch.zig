// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! A Zig wrapper around the `notmuch` C APIs for dealing with
//! lists of threads.
pub const ThreadsIterator = @This();

const std = @import("std");

const c = @import("c");

const Thread = @import("Thread.zig");
const status = @import("enums.zig").status;

/// The underlying `notmuch_threads_t` handle, or `null` for an iterator
/// over an empty list.
threads: ?*c.notmuch_threads_t,

pub const NextError = error{
    /// Iteration failed to allocate memory.
    OutOfMemory,
    /// Iteration was invalidated by the database. Re-open the database and
    /// try again.
    OperationInvalidated,
    /// The item could not be built out of the database.
    ///
    /// `notmuch_threads_get` is documented to return NULL only for an
    /// out-of-memory situation, but the thread is constructed on demand out
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

pub fn next(self: *ThreadsIterator) NextError!?Thread {
    const threads = self.threads orelse return null;
    return switch (status(c.notmuch_threads_status(threads))) {
        .success => thread: {
            if (c.notmuch_threads_valid(threads) == 0) break :thread null;
            defer c.notmuch_threads_move_to_next(threads);
            break :thread .{
                .thread = c.notmuch_threads_get(threads) orelse return error.XapianException,
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
    var threads = try query.searchThreads();
    defer threads.deinit();

    // The corpus's four messages form three threads; after exhaustion,
    // next keeps returning null.
    var count: usize = 0;
    while (try threads.next()) |thread| : (count += 1) thread.deinit();
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(try threads.next() == null);
}

/// Deinitialize a `ThreadsIterator` object.
///
/// It's not strictly necessary to call this function. All memory from
/// the `ThreadsIterator` object will be reclaimed when the
/// containing query object is deinitialized.
pub fn deinit(self: *ThreadsIterator) void {
    const threads = self.threads orelse return;
    c.notmuch_threads_destroy(threads);
}
