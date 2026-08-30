// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Iterator over a `;`-delimited list of configuration values, as returned
//! by `Database.configGetValues` and `Database.configGetValuesString`.
//!
//! The strings returned by `next` live only as long as the iterator; `start`
//! resets iteration to the first value.
pub const ValuesIterator = @This();

const std = @import("std");
const c = @import("c");

/// The underlying `notmuch_config_values_t` handle; only needed directly
/// when calling libnotmuch C APIs these bindings do not wrap.
values: *c.notmuch_config_values_t,

/// Get the next value, or `null` if there are no more values.
///
/// The returned string has the same lifetime as the iterator: it is
/// invalidated by the next call to `next` or by `deinit`.
pub fn next(self: *ValuesIterator) ?[:0]const u8 {
    if (c.notmuch_config_values_valid(self.values) == 0) return null;
    defer c.notmuch_config_values_move_to_next(self.values);
    return std.mem.span(c.notmuch_config_values_get(self.values) orelse unreachable);
}

test next {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    try db.configSet(.exclude_tags, "spam;deleted");

    // Values are yielded in configuration order; after exhaustion, next
    // keeps returning null.
    var values = db.configGetValues(.exclude_tags) orelse return error.TestUnexpectedResult;
    defer values.deinit();
    try std.testing.expectEqualStrings("spam", values.next() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("deleted", values.next() orelse return error.TestUnexpectedResult);
    try std.testing.expect(values.next() == null);
}

/// Reset the `ValuesIterator` to the first element.
pub fn start(self: *ValuesIterator) void {
    c.notmuch_config_values_start(self.values);
}

test start {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    try db.configSet(.exclude_tags, "spam;deleted");

    var values = db.configGetValues(.exclude_tags) orelse return error.TestUnexpectedResult;
    defer values.deinit();
    while (values.next()) |_| {}

    // start rewinds the exhausted iterator to the first value.
    values.start();
    try std.testing.expectEqualStrings("spam", values.next() orelse return error.TestUnexpectedResult);
}

/// Deinitialize a config values iterator, along with any associated
/// resources.
pub fn deinit(self: *ValuesIterator) void {
    c.notmuch_config_values_destroy(self.values);
}

test {
    std.testing.refAllDecls(@This());
}
