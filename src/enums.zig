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
pub const Config = generateEnum("NOTMUCH_CONFIG_", &.{ "NOTMUCH_CONFIG_FIRST", "NOTMUCH_CONFIG_LAST" });

pub const DatabaseMode = generateEnum("NOTMUCH_DATABASE_MODE_", &.{});

pub const Decrypt = generateEnum("NOTMUCH_DECRYPT_", &.{});

/// Exclude values for `Query.setOmitExcluded`
pub const Exclude = generateEnum("NOTMUCH_EXCLUDE_", &.{});

pub const MessageFlag = generateEnum("NOTMUCH_MESSAGE_FLAG_", &.{});

/// query syntax
pub const QuerySyntax = generateEnum("NOTMUCH_QUERY_SYNTAX_", &.{});

/// Sort values for notmuch_query_set_sort.
pub const Sort = generateEnum("NOTMUCH_SORT_", &.{});

/// Status codes used for the return values of most functions.
pub const Status = generateEnum("NOTMUCH_STATUS_", &.{"NOTMUCH_STATUS_LAST_STATUS"});

/// Convenience function to convert a notmuch API return code to a Status enum.
pub fn status(rc: c_uint) Status {
    return @enumFromInt(rc);
}
