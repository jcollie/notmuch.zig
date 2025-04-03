const Thread = @This();

const std = @import("std");

const c = @import("c.zig").c;

const Error = @import("error.zig").Error;
const wrap = @import("error.zig").wrap;

const MessagesIterator = @import("MessagesIterator.zig");
const TagsIterator = @import("TagsIterator.zig");

thread: *c.notmuch_thread_t,

/// Get the thread ID of 'thread'.
///
/// The returned string belongs to 'thread' and as such, should not be modified
/// by the caller and will only be valid for as long as the thread is valid,
/// (which is until notmuch_thread_destroy or until the query from which it
/// derived is destroyed).
pub fn getThreadID(self: *const Thread) [:0]const u8 {
    return std.mem.span(c.notmuch_thread_get_thread_id(self.thread));
}

/// Get the total number of messages in 'thread'.
///
/// This count consists of all messages in the database belonging to this
/// thread. Contrast with getMatchedMessages().
pub fn getTotalMessages(self: *const Thread) usize {
    return @intCast(c.notmuch_thread_get_total_messages(self.thread));
}

/// Get the number of messages in 'thread' that matched the search.
///
/// This count includes only the messages in this thread that were matched by
/// the search from which the thread was created and were not excluded by any
/// exclude tags passed in with the query (see Query.addTagExclude). Contrast
/// with getTotalMessages() .
pub fn getMatchedMessages(self: *const Thread) usize {
    return @intCast(c.notmuch_thread_get_matched_messages(self.thread));
}

/// Get the total number of files in 'thread'.
///
/// This sums Message.countFiles over all messages in the thread.
pub fn getTotalFiles(self: *const Thread) usize {
    return @intCast(c.notmuch_thread_get_total_files(self.thread));
}

/// Get a MessagesIterator for the top-level messages in 'thread' in
/// oldest-first order.
///
/// This iterator will not necessarily iterate over all of the messages in the
/// thread. It will only iterate over the messages in the thread which are not
/// replies to other messages in the thread.
///
/// The returned list will be destroyed when the thread is destroyed.
pub fn getToplevelMessages(self: *const Thread) MessagesIterator {
    return .{
        .messages = c.notmuch_thread_get_toplevel_messages(self.thread),
    };
}

// Get a MessagesIterator for all messages in 'thread' in oldest-first order.
pub fn getMessages(self: *const Thread) MessagesIterator {
    return .{
        .messages = c.notmuch_thread_get_messages(self.thread),
    };
}

/// Get the authors of 'thread' as a UTF-8 string.
///
/// The returned string is a comma-separated list of the names of the authors of
/// mail messages in the query results that belong to this thread.
///
/// The string contains authors of messages matching the query first, then
/// non-matched authors (with the two groups separated by '|'). Within each
/// group, authors are ordered by date.
///
/// The returned string belongs to 'thread' and as such, should not be modified
/// by the caller and will only be valid for as long as the thread is valid,
/// (which is until notmuch_thread_destroy or until the query from which it
/// derived is destroyed).
pub fn getAuthors(self: *const Thread) [:0]const u8 {
    return std.mem.span(c.notmuch_thread_get_authors(self.thread));
}

/// Get the subject of 'thread' as a UTF-8 string.
///
/// The subject is taken from the first message (according to the query
/// order---see Query.setSort) in the query results that belongs to this thread.
///
/// The returned string belongs to 'thread' and as such, should not be modified
/// by the caller and will only be valid for as long as the thread is valid,
/// (which is until notmuch_thread_destroy or until the query from which it
/// derived is destroyed).
pub fn getSubject(self: *const Thread) [:0]const u8 {
    return std.mem.span(c.notmuch_thread_get_subject(self.thread));
}

/// Get the date of the oldest message in 'thread' as a nanosecond timestamp.
pub fn getOldestDate(self: *const Thread) i128 {
    return c.notmuch_thread_get_oldest_date(self.thread) * std.time.ns_per_s;
}

/// Get the date of the newest message in 'thread' as a nanosecond timestamp.
pub fn getNewestDate(self: *const Thread) i128 {
    return c.notmuch_thread_get_newest_date(self.thread) * std.time.ns_per_s;
}

/// Get the tags for 'thread', returning a TagsIterator object which can be used
/// to iterate over all tags.
///
/// Note: In the Notmuch database, tags are stored on individual messages, not
/// on threads. So the tags returned here will be all tags of the messages which
/// matched the search and which belong to this thread.
///
/// The tags object is owned by the thread and as such, will only be valid for
/// as long as the thread is valid, (for example, until notmuch_thread_destroy
/// or until the query from which it derived is destroyed).
pub fn getTags(self: *const Thread) TagsIterator {
    return .{
        .tags = c.notmuch_thread_get_tags(self.thread),
    };
}

pub fn deinit(self: *const Thread) void {
    c.notmuch_thread_destroy(self.thread);
}
