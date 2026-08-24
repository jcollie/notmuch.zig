// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! A Zig wrapper around the `notmuch` C APIs for dealing with
//! lists of messages.
const MessagesIterator = @This();

const c = @import("c");

const Message = @import("Message.zig");
const TagsIterator = @import("TagsIterator.zig");
const status = @import("enums.zig").status;

messages: ?*c.notmuch_messages_t,

pub const NextError = error{
    /// Iteration failed to allocate memory.
    OutOfMemory,
    /// Iteration was invalidated by the database. Re-open the database and
    /// try again.
    OperationInvalidated,
};

/// Return a list of tags from all messages.
///
/// The resulting list is guaranteed not to contain duplicated tags.
///
/// WARNING: You can no longer iterate over messages after calling this
/// function, because the iterator will point at the end of the list. We do
/// not have a function to reset the iterator yet and the only way how you can
/// iterate over the list again is to recreate the message list.
///
/// The function returns `null` on error.
pub fn collectTags(self: *const MessagesIterator) ?TagsIterator {
    const messages = self.messages orelse return null;
    return .{
        .tags = c.notmuch_messages_collect_tags(messages) orelse return null,
    };
}

pub fn next(self: *const MessagesIterator) NextError!?Message {
    const messages = self.messages orelse return null;
    return switch (status(c.notmuch_messages_status(messages))) {
        .success => message: {
            if (c.notmuch_messages_valid(messages) == 0) break :message null;
            defer c.notmuch_messages_move_to_next(messages);
            break :message .{
                .message = c.notmuch_messages_get(messages) orelse unreachable,
            };
        },
        .iterator_exhausted => return null,
        .operation_invalidated => error.OperationInvalidated,
        .out_of_memory => error.OutOfMemory,
        else => unreachable,
    };
}

/// Deinitialize a `MessageIterator` object.
///
/// It's not strictly necessary to call this function. All memory from
/// the `MessageIterator` object will be reclaimed when the
/// containing query object is deinitialized.
pub fn deinit(self: *const MessagesIterator) void {
    const messages = self.messages orelse return;
    c.notmuch_messages_destroy(messages);
}
