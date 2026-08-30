// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Iterator over (key, value) configuration pairs, as returned by
//! `Database.configGetPairs`.
//!
//! The strings returned by `next` live only as long as the iterator.
pub const PairsIterator = @This();

const std = @import("std");
const c = @import("c");

/// The underlying `notmuch_config_pairs_t` handle; only needed directly
/// when calling libnotmuch C APIs these bindings do not wrap.
pairs: *c.notmuch_config_pairs_t,

pub const Pair = struct {
    key: [:0]const u8,
    /// `null` when the key has no value defined.
    value: ?[:0]const u8,
};

/// Get the next pair, or `null` if there are no more pairs.
///
/// The returned strings have the same lifetime as the iterator: they are
/// invalidated by the next call to `next` or by `deinit`.
pub fn next(self: *PairsIterator) ?Pair {
    if (c.notmuch_config_pairs_valid(self.pairs) == 0) return null;
    defer c.notmuch_config_pairs_move_to_next(self.pairs);
    const value = c.notmuch_config_pairs_value(self.pairs);
    return .{
        .key = std.mem.span(c.notmuch_config_pairs_key(self.pairs) orelse unreachable),
        .value = if (value == null) null else std.mem.span(value),
    };
}

test next {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    try db.configSet(.user_name, "Test User");

    // Each pair carries the full dotted key and its value; a key with no
    // value yields a null value.
    var pairs = db.configGetPairs("user.") orelse return error.TestUnexpectedResult;
    defer pairs.deinit();
    var saw_name = false;
    while (pairs.next()) |pair| {
        if (std.mem.eql(u8, pair.key, "user.name")) {
            saw_name = true;
            try std.testing.expectEqualStrings("Test User", pair.value orelse "");
        }
    }
    try std.testing.expect(saw_name);
}

/// Deinitialize a config pairs iterator, along with any associated resources.
pub fn deinit(self: *PairsIterator) void {
    c.notmuch_config_pairs_destroy(self.pairs);
}
