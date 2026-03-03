// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

const Query = @This();

const std = @import("std");

const c = @import("c");

const status = @import("enums.zig").status;
const Error = @import("error.zig").Error;
const wrap = @import("error.zig").wrap;

const Exclude = @import("enums.zig").Exclude;
const Sort = @import("enums.zig").Sort;

const Database = @import("Database.zig");
const MessagesIterator = @import("MessagesIterator.zig");
const ThreadsIterator = @import("ThreadsIterator.zig");

query: *c.notmuch_query_t,

pub fn init(query: *c.notmuch_query_t) Query {
    return .{ .query = query };
}

/// Return the query string of this query. See `Database.queryCreate`
pub fn getQueryString(self: *const Query) [:0]const u8 {
    return std.mem.span(c.notmuch_query_get_query_string(self.query));
}

/// Return the notmuch database of this query. See `Database.queryCreate`.
pub fn getDatabase(self: *const Query) ?Database {
    return .{
        .database = c.notmuch_query_get_database(self.query) orelse null,
    };
}

/// Specify whether to omit excluded results or simply flag them. By default,
/// this is set to `true`.
///
/// If set to `true` or `all`, `searchMessages` will omit excluded messages
/// from the results, and `searchThreads` will omit threads that match only
/// in excluded messages. If set to `true`, `searchThreads` will include
/// all messages in threads that match in at least one non-excluded message.
/// Otherwise, if set to `all`, `searchThreads` will omit excluded messages from
/// all threads.
///
/// If set to `false` or `flag` then both `searchMessages` and `searchThreads`
/// will return all matching messages/threads regardless of exclude status.
/// If set to `flag` then the exclude flag will be set for any excluded
/// message that is returned by `searchMessages`, and the thread counts for
/// threads returned by `searchThreads` will be the number of non-excluded
/// messages/matches. Otherwise, if set to `false`, then the exclude status is
/// completely ignored.
///
/// The performance difference when calling `searchMessages` should be
/// relatively small (and both should be very fast). However, in some cases,
/// `searchThreads` is very much faster when omitting excluded messages as it
/// does not need to construct the threads that only match in excluded messages.
pub fn setOmitExcluded(self: *const Query, omit_excluded: Exclude) void {
    c.notmuch_query_set_omit_excluded(self.query, @intFromEnum(omit_excluded));
}

/// Specify the sorting desired for this query.
pub fn setSort(self: *const Query, sort: Sort) void {
    c.notmuch_query_set_sort(self.query, @intFromEnum(sort));
}

/// Return the sort specified for this query.
pub fn getSort(self: *const Query) Sort {
    return @enumFromInt(c.notmuch_query_get_sort(self.query));
}

pub const AddTagExcludeError = error{
    /// The tag is explicitly present in the query, so not excluded.
    Ignored,
    /// A Xapian exception occurred. Most likely a problem lazily parsing the
    /// query string.
    XapianException,
};

/// Add a tag that will be excluded from the query results by default. This
/// exclusion will be ignored if this tag appears explicitly in the query.
///
/// Errors returned:
///
/// XapianException: a Xapian exception occurred. Most likely a problem lazily
///   parsing the query string.
///
/// Ignored: tag is explicitly present in the query, so not excluded.
pub fn addTagExclude(self: *const Query, tag: [:0]const u8) AddTagExcludeError!void {
    return switch (status(c.notmuch_query_add_tag_exclude(self.query, tag))) {
        .success => {},
        .ignored => error.Ignored,
        .xapian_exception => error.XapianException,
        else => unreachable,
    };
}

/// Execute a query for threads, returning a `ThreadsIterator` object which can
/// be used to iterate over the results. The returned threads object is owned by
/// the query and as such, will only be valid until `Query.deinit`.
///
/// Typical usage might be:
/// ```
///   const db = try Database.open(…);
///   defer db.deinit();
///   const query = db.queryCreate(query_string);
///   defer query.deinit();
///   var it = query.searchThreads();
///   defer it.deinit();
///   while (try it.next()) |thread| {
///       defer thread.deinit();
///       …
///   }
/// ```
///
/// Note: If you are finished with a thread before its containing query, you
/// can call `ThreadsIterator.deinit` to clean up some memory sooner (as in the
/// above example). Otherwise, if your thread objects are long-lived, then you
/// don't need to call `ThreadsIterator.deinit` and all the memory will still be
/// reclaimed when the query is destroyed.
pub fn searchThreads(self: *const Query) Error!ThreadsIterator {
    var threads: ?*c.notmuch_threads_t = null;

    try wrap(c.notmuch_query_search_threads(self.query, &threads));

    return .{
        .threads = threads,
    };
}

/// Execute a query for messages, returning a MessagesIterator object which can
/// be used to iterate over the results. The returned messages object is owned
/// by the query and as such, will only be valid until `Query.deinit`.
///
/// Typical usage might be:
/// ```
///   const db = try Database.open(…);
///   defer db.deinit();
///   const query = db.queryCreate(query_string);
///   defer query.deinit();
///   var it = query.searchMessages();
///   defer it.deinit();
///   while (try it.next()) |message| {
///       defer message.deinit();
///       …
///   }
/// ```
///
/// Note: If you are finished with a message before its containing query, you
/// can call `Message.deinit` to clean up some memory sooner (as in the
/// above example). Otherwise, if your message objects are long-lived, then you
/// don't need to call `Message.deinit` and all the memory will still be
/// reclaimed when the query is deinitialized.
pub fn searchMessages(self: *const Query) Error!MessagesIterator {
    var out: ?*c.notmuch_messages_t = undefined;

    try wrap(c.notmuch_query_search_messages(self.query, &out));

    return .{
        .messages = out,
    };
}

pub const CountMessagesError = error{
    /// A Xapian error occurred.
    XapianError,
};

/// Return the number of messages matching a search.
///
/// This function performs a search and returns the number of matching messages.
pub fn countMessages(self: *const Query) CountMessagesError!u32 {
    std.debug.assert(@typeInfo(c_uint).int.bits == 32);
    var count: c_uint = undefined;
    return switch (status(c.notmuch_query_count_messages(self.query, &count))) {
        .success => @intCast(count),
        .xapian_error => error.XapianError,
        else => unreachable,
    };
}

pub const CountThreadsError = error{
    /// Memory allocation failed.
    OutOfMemory,
    /// A Xapian error occurred.
    XapianError,
};

/// Return the number of threads matching a search.
///
/// This function performs a search and returns the number of unique thread IDs
/// in the matching messages. This is the same as number of threads matching
/// a search.
///
/// Note that this is a significantly heavier operation than
/// `countMessages`.
pub fn countThreads(self: *const Query) CountThreadsError!u32 {
    std.debug.assert(@typeInfo(c_uint).int.bits == 32);
    var count: c_uint = undefined;
    return switch (status(c.notmuch_query_count_threads(self.query, &count))) {
        .success => @intCast(count),
        .out_of_memory => error.OutOfMemory,
        .xapian_exception => error.XapianError,
        else => unreachable,
    };
}

/// Deinitialize the `Query` along with any associated resources.
///
/// This will in turn deinitialize any `ThreadsIterator` and `MessageIterator`
/// objects generated by this query, (and in turn any `Thread` and `Message`
/// objects generated from those results, etc.), if such objects haven't already
/// been deinitialized.
pub fn deinit(self: *const Query) void {
    c.notmuch_query_destroy(self.query);
}
