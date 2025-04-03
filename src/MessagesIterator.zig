const MessagesIterator = @This();

const c = @import("c.zig").c;

const Message = @import("Message.zig");

messages: ?*c.notmuch_messages_t,

pub fn next(self: *MessagesIterator) ?Message {
    const messages = self.messages orelse return null;
    if (c.notmuch_messages_valid(messages)) return null;
    defer c.notmuch_messages_move_to_next(messages);
    return .{
        .message = c.notmuch_threads_get(messages) orelse unreachable,
    };
}

pub fn deinit(self: *MessagesIterator) void {
    c.notmuch_threads_destroy(self.threads);
}
