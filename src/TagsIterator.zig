const TagsIterator = @This();

const std = @import("std");

const c = @import("c.zig").c;

tags: ?*c.notmuch_tags_t,

pub fn next(self: *TagsIterator) ?[:0]const u8 {
    const tags = self.tags orelse return null;
    if (c.notmuch_tags_valid(tags) == 0) return null;
    defer c.notmuch_tags_move_to_next(tags);
    return std.mem.span(c.notmuch_tags_get(tags) orelse unreachable);
}

pub fn deinit(self: *TagsIterator) void {
    c.notmuch_tags_destroy(self.tags);
}
