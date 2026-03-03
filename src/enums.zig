// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

const c = @import("c");

/// Generate Zig enums from C enums that begin with a prefix. Skip creating
/// enums for certain names.
fn generateEnum(comptime prefix: []const u8, skips: []const []const u8) type {
    @setEvalBranchQuota(24000);
    const info = @typeInfo(c);
    var count = 0;
    var max = 0;
    outer: for (info.@"struct".decls) |decl| {
        for (skips) |skip| if (std.mem.eql(u8, skip, decl.name)) continue :outer;
        if (std.mem.startsWith(u8, decl.name, prefix)) {
            max = @max(max, @field(c, decl.name));
            count += 1;
        }
    }
    const TagType = std.math.IntFittingRange(0, max);
    var field_names: [count][]const u8 = undefined;
    var field_values: [count]TagType = undefined;
    var index = 0;
    outer: for (info.@"struct".decls) |decl| {
        for (skips) |skip| if (std.mem.eql(u8, skip, decl.name)) continue :outer;
        if (std.mem.cutPrefix(u8, decl.name, prefix)) |suffix| {
            var buf: [suffix.len]u8 = undefined;
            field_names[index] = std.ascii.lowerString(&buf, suffix);
            field_values[index] = @field(c, decl.name);
            index += 1;
        }
    }
    return @Enum(
        TagType,
        .exhaustive,
        &field_names,
        &field_values,
    );
}

/// Configuration keys known to notmuch.
pub const CONFIG = generateEnum("NOTMUCH_CONFIG_", &.{ "NOTMUCH_CONFIG_FIRST", "NOTMUCH_CONFIG_LAST" });

pub const DATABASE_MODE = generateEnum("NOTMUCH_DATABASE_MODE_", &.{});

pub const Decrypt = generateEnum("NOTMUCH_DECRYPT_", &.{});

/// Exclude values for `Query.setOmitExcluded`
pub const EXCLUDE = generateEnum("NOTMUCH_EXCLUDE_", &.{});

pub const MESSAGE_FLAG = generateEnum("NOTMUCH_MESSAGE_FLAG_", &.{});

/// query syntax
pub const QUERY_SYNTAX = generateEnum("NOTMUCH_QUERY_SYNTAX_", &.{});

/// Sort values for notmuch_query_set_sort.
pub const SORT = generateEnum("NOTMUCH_SORT_", &.{});

/// Status codes used for the return values of most functions.
pub const STATUS = generateEnum("NOTMUCH_STATUS_", &.{"NOTMUCH_STATUS_LAST_STATUS"});

/// Convenience function to convert a notmuch API return code to a STATUS enum.
pub fn status(rc: c_uint) STATUS {
    return @enumFromInt(rc);
}
