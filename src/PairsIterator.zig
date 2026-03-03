// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Zig wrapper around the `notmuch` C APIs that deal with config pair lists.
pub const PairsIterator = @This();

const std = @import("std");
const c = @import("c");

pairs: *c.notmuch_config_pairs_t,

pub const Pair = struct {
    key: [:0]const u8,
    value: [:0]const u8,
};

/// Get the next pair, or `null` if there are no more pairs.
pub fn next(self: *PairsIterator) ?Pair {
    if (c.notmuch_config_pairs_valid(self.pairs) == 0) return null;
    defer c.notmuch_config_pairs_move_to_next(self.pairs);
    return .{
        .key = std.mem.span(c.notmuch_config_pairs_key(self.pairs) orelse unreachable),
        .value = std.mem.span(c.notmuch_config_pairs_value(self.pairs) orelse unreachable),
    };
}

/// Deinitialize a config pairs iterator, along with any associated resources.
pub fn deinit(self: *PairsIterator) void {
    c.notmuch_config_pairs_destroy(self.pairs);
}
