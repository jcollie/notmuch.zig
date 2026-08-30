// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Iterator over the (key, value) properties of a message, as returned by
//! `Message.getProperties`.
//!
//! Owned by the message it came from and valid only as long as the message.
const PropertiesIterator = @This();

const std = @import("std");
const c = @import("c");

/// The underlying `notmuch_message_properties_t` handle, or `null` for an
/// iterator over an empty list.
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

test next {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try message.addProperty("zig.key", "first");
    try message.addProperty("zig.key", "second");

    // Each entry is a key/value pair; multiple values for one key yield
    // one entry per value. After exhaustion, next keeps returning null.
    var properties = message.getProperties("zig.key", true);
    defer properties.deinit();
    var count: usize = 0;
    while (properties.next()) |kv| : (count += 1)
        try std.testing.expectEqualStrings("zig.key", kv.key);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(properties.next() == null);
}

pub fn deinit(self: PropertiesIterator) void {
    const properties = self.properties orelse return;
    c.notmuch_message_properties_destroy(properties);
}

test {
    _ = std.testing.refAllDecls(@This());
}
