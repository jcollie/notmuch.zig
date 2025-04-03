pub const ThreadsIterator = @This();

const c = @import("c.zig").c;

const Thread = @import("Thread.zig");

threads: ?*c.notmuch_threads_t,

pub fn next(self: *ThreadsIterator) ?Thread {
    const threads = self.threads orelse return null;
    if (c.notmuch_threads_valid(threads)) return null;
    defer c.notmuch_threads_move_to_next(threads);
    return .{
        .thread = c.notmuch_threads_get(threads) orelse unreachable,
    };
}

pub fn deinit(self: *ThreadsIterator) void {
    c.notmuch_threads_destroy(self.threads);
}
