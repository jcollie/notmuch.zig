const Query = @This();

const std = @import("std");

const c = @import("c.zig").c;

const Error = @import("error.zig").Error;
const wrap = @import("error.zig").wrap;

const EXCLUDE = @import("enums.zig").EXCLUDE;
const SORT = @import("enums.zig").SORT;

const MessagesIterator = @import("MessagesIterator.zig");
const ThreadsIterator = @import("ThreadsIterator.zig");

query: *c.notmuch_query_t,

/// Return the query_string of this query.
pub fn getQueryString(self: *const Query) [:0]const u8 {
    return std.mem.span(c.notmuch_query_get_query_string(self.query));
}

/// Specify whether to omit excluded results or simply flag them.  By default,
/// this is set to TRUE.
///
/// If set to TRUE or ALL, notmuch_query_search_messages will omit excluded
/// messages from the results, and notmuch_query_search_threads will
/// omit threads that match only in excluded messages.  If set to TRUE,
/// notmuch_query_search_threads will include all messages in threads that
/// match in at least one non-excluded message.  Otherwise, if set to ALL,
/// notmuch_query_search_threads will omit excluded messages from all threads.
///
/// If set to FALSE or FLAG then both notmuch_query_search_messages and
/// notmuch_query_search_threads will return all matching messages/threads
/// regardless of exclude status. If set to FLAG then the exclude
/// flag will be set for any excluded message that is returned by
/// notmuch_query_search_messages, and the thread counts for threads returned
/// by notmuch_query_search_threads will be the number of non-excluded
/// messages/matches. Otherwise, if set to FALSE, then the exclude status is
/// completely ignored.
///
/// The performance difference when calling notmuch_query_search_messages should
/// be relatively small (and both should be very fast).  However, in some cases,
/// notmuch_query_search_threads is very much faster when omitting excluded
/// messages as it does not need to construct the threads that only match in
/// excluded messages.
pub fn setOmitExcluded(self: *const Query, omit_excluded: EXCLUDE) void {
    c.notmuch_query_set_omit_excluded(self.query, @intFromEnum(omit_excluded));
}

/// Specify the sorting desired for this query.
pub fn setSort(self: *const Query, sort: SORT) void {
    c.notmuch_query_set_sort(self.query, @intFromEnum(sort));
}

/// Return the sort specified for this query.
pub fn getSort(self: *const Query) SORT {
    return @enumFromInt(c.notmuch_query_get_sort(self.query));
}

/// Add a tag that will be excluded from the query results by default. This
/// exclusion will be ignored if this tag appears explicitly in the query.
///
/// Errors returned:
///
/// XapianException: a Xapian exception occurred. Most likely a problem lazily
///   parsing the query string.
///
/// Ignored: tag is explicitly present in the query, so not excluded.
pub fn addTagExclude(self: *const Query, tag: [:0]const u8) Error!void {
    try wrap(c.notmuch_query_add_tag_exclude(self.query, tag));
}

/// Execute a query for threads, returning a ThreadsIterator object which can
/// be used to iterate over the results. The returned threads object is owned by
/// the query and as such, will only be valid until `Query.deinit`.
///
/// Note: If you are finished with a thread before its containing query, you
/// can call `Thread.deinit` to clean up some memory sooner (as in the above
/// example). Otherwise, if your thread objects are long-lived, then you don't
/// need to call `Thread.deinit` and all the memory will still be reclaimed when
/// the query is destroyed.
pub fn searchThreads(self: *const Query) Error!ThreadsIterator {
    var out: ?*c.notmuch_threads_t = undefined;

    try wrap(c.notmuch_query_search_threads(self.query, &out));

    return .{
        .threads = out,
    };
}

/// Execute a query for messages, returning a MessagesIterator object which can
/// be used to iterate over the results. The returned messages object is owned
/// by the query and as such, will only be valid until Query.deinit.
///
/// Note: If you are finished with a message before its containing query, you
/// can call Message.deinit to clean up some memory sooner (as in the
/// above example). Otherwise, if your message objects are long-lived, then you
/// don't need to call Message.deinit and all the memory will still be
/// reclaimed when the query is destroyed.
pub fn searchMessages(self: *const Query) Error!MessagesIterator {
    var out: ?*c.notmuch_messages_t = undefined;

    try wrap(c.notmuch_query_search_messages(self.query, &out));

    return .{
        .messages = out,
    };
}

/// Return the number of messages matching a search.
///
/// This function performs a search and returns the number of matching messages.
pub fn countMessages(self: *const Query) Error!usize {
    var count: c_uint = undefined;
    try wrap(c.notmuch_query_count_messages(self.query, &count));
    return @intCast(count);
}

/// Return the number of threads matching a search.
///
/// This function performs a search and returns the number of matching threads.
pub fn countThreads(self: *const Query) Error!usize {
    var count: c_uint = undefined;
    try wrap(c.notmuch_query_count_threads(self.query, &count));
    return @intCast(count);
}

pub fn deinit(self: *const Query) void {
    c.notmuch_query_destroy(self.query);
}
