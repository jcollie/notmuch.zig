// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Zig wrapper around the `notmuch` C APIs that deal with property lists.
const PropertiesIterator = @This();

const std = @import("std");
const c = @import("c");

properties: ?*c.notmuch_message_properties_t,

pub const KV = struct {
    key: [:0]const u8,
    value: [:0]const u8,
};

pub fn next(self: PropertiesIterator) ?KV {
    const properties = self.properties orelse return null;
    if (c.notmuch_message_properties_valid(properties) == 0) return null;
    defer c.notmuch_message_properties_move_to_next(properties);
    return .{
        .key = std.mem.span(c.notmuch_message_properties_key(properties) orelse unreachable),
        .value = std.mem.span(c.notmuch_message_properties_value(properties) orelse unreachable),
    };
}

pub fn deinit(self: PropertiesIterator) void {
    const properties = self.properties orelse return;
    c.notmuch_message_properties_destroy(properties);
}

test {
    _ = std.testing.refAllDecls(@This());
}
