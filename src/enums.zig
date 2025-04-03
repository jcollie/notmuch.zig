const std = @import("std");

const c = @import("c.zig").c;

fn generateEnum(comptime prefix: []const u8, skips: []const []const u8) type {
    @setEvalBranchQuota(24000);
    const info = @typeInfo(c);
    var count: usize = 0;
    outer: for (info.@"struct".decls) |decl| {
        for (skips) |skip| if (std.mem.eql(u8, skip, decl.name)) continue :outer;
        if (std.mem.startsWith(u8, decl.name, prefix)) {
            count += 1;
        }
    }
    var fields: [count]std.builtin.Type.EnumField = undefined;
    var index: usize = 0;
    var max: c.notmuch_status_t = 0;
    outer: for (info.@"struct".decls) |decl| {
        for (skips) |skip| if (std.mem.eql(u8, skip, decl.name)) continue :outer;
        if (std.mem.startsWith(u8, decl.name, prefix)) {
            max = @max(max, @field(c, decl.name));
            fields[index] = .{
                .name = decl.name[prefix.len..],
                .value = @field(c, decl.name),
            };
            index += 1;
        }
    }
    return @Type(
        .{
            .@"enum" = .{
                .tag_type = std.math.IntFittingRange(0, max),
                .fields = &fields,
                .decls = &.{},
                .is_exhaustive = true,
            },
        },
    );
}

/// Configuration keys known to notmuch.
pub const CONFIG = generateEnum("NOTMUCH_CONFIG_", &.{ "NOTMUCH_CONFIG_FIRST", "NOTMUCH_CONFIG_LAST" });

pub const DATABASE_MODE = generateEnum("NOTMUCH_DATABASE_MODE_", &.{});

pub const DECRYPT = generateEnum("NOTMUCH_DECRYPT_", &.{});

/// Exclude values for `Query.setOmitExcluded`
pub const EXCLUDE = generateEnum("NOTMUCH_EXCLUDE_", &.{});

pub const MESSAGE_FLAG = generateEnum("NOTMUCH_MESSAGE_FLAG_", &.{});

/// query syntax
pub const QUERY_SYNTAX = generateEnum("NOTMUCH_QUERY_SYNTAX_", &.{});

/// Sort values for notmuch_query_set_sort.
pub const SORT = generateEnum("NOTMUCH_SORT_", &.{});

pub const STATUS = generateEnum("NOTMUCH_STATUS_", &.{"NOTMUCH_STATUS_LAST_STATUS"});
