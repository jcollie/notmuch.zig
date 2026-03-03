// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Zig wrapper around the `notmuch` C APIs that deal with value lists.
pub const ValuesIterator = @This();

const std = @import("std");
const c = @import("c");

values: *c.notmuch_config_values_t,

/// Get the next value, or `null` if there are no more values.
pub fn next(self: *ValuesIterator) ?[:0]const u8 {
    if (c.notmuch_config_values_valid(self.values) == 0) return null;
    defer c.notmuch_config_values_move_to_next(self.values);
    return std.mem.span(c.notmuch_config_values_get(self.values) orelse unreachable);
}

/// Reset the `ValuesIterator` to the first element.
pub fn start(self: *ValuesIterator) void {
    c.notmuch_config_values_start(self.values);
}

/// Deinitialize a config values iterator, along with any associated
/// resources.
pub fn deinit(self: *ValuesIterator) void {
    c.notmuch_config_values_destroy(self.values);
}

test {
    std.testing.refAllDecls(@This());
}
