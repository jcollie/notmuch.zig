const Database = @This();

const std = @import("std");
const log = std.log.scoped(.notmuch);

const c = @import("c.zig").c;

const Error = @import("error.zig").Error;
const wrap = @import("error.zig").wrap;
const wrapMessage = @import("error.zig").wrapMessage;

const CONFIG = @import("enums.zig").CONFIG;
const DATABASE_MODE = @import("enums.zig").DATABASE_MODE;
const DECRYPT = @import("enums.zig").DECRYPT;
const QUERY_SYNTAX = @import("enums.zig").QUERY_SYNTAX;

const Message = @import("Message.zig");
const Query = @import("Query.zig");

database: *c.notmuch_database_t,

pub fn open(
    database_path: ?[*:0]const u8,
    mode: DATABASE_MODE,
    config_path: ?[:0]const u8,
    profile: ?[:0]const u8,
) Error!Database {
    if (!c.LIBNOTMUCH_CHECK_VERSION(5, 6, 0)) {
        log.err("need newer notmuch", .{});
        return error.NotmuchVersion;
    }

    var error_message: [*c]u8 = null;
    var database: ?*c.notmuch_database_t = null;
    try wrapMessage(c.notmuch_database_open_with_config(
        database_path orelse null,
        @intFromEnum(mode),
        config_path orelse null,
        profile orelse null,
        &database,
        &error_message,
    ), error_message);
    return .{
        .database = database orelse unreachable,
    };
}

pub fn create(
    database_path: ?[*:0]const u8,
    config_path: ?[:0]const u8,
    profile: ?[:0]const u8,
) Error!Database {
    if (!c.LIBNOTMUCH_CHECK_VERSION(5, 6, 0)) {
        log.err("need newer notmuch", .{});
        return error.NotmuchVersion;
    }

    var error_message: [*c]u8 = null;
    var database: ?*c.notmuch_database_t = null;
    try wrapMessage(
        c.notmuch_database_create_with_config(
            database_path orelse null,
            config_path orelse null,
            profile orelse null,
            &database,
            &error_message,
        ),
        error_message,
    );
    return .{
        .database = database orelse unreachable,
    };
}

pub fn close(self: *const Database) void {
    _ = c.notmuch_database_close(self.database);
}

pub fn indexFile(self: *const Database, filename: [:0]const u8, indexopts: ?IndexOpts) Error!void {
    try wrap(c.notmuch_database_index_file(
        self.database,
        filename,
        if (indexopts) |i| i.indexopts else null,
        null,
    ));
}

pub fn indexFileGetMessage(self: *const Database, filename: [:0]const u8, indexopts: ?IndexOpts) Error!Message {
    var message: ?*c.notmuch_message_t = null;
    wrap(c.notmuch_database_index_file(
        self.database,
        filename,
        if (indexopts) |i| i.indexopts else null,
        &message,
    )) catch |err| switch (err) {
        error.DuplicateMessageID => return .{
            .duplicate = true,
            .message = message orelse unreachable,
        },
        else => |e| return e,
    };
    return .{
        .duplicate = false,
        .message = message orelse unreachable,
    };
}

pub fn findMessageByFilename(self: *const Database, filename: [:0]const u8) Error!Message {
    var message: ?*c.notmuch_message_t = null;
    try wrap(c.notmuch_database_find_message_by_filename(self.database, filename, &message));
    return .{
        .message = message orelse unreachable,
    };
}

pub fn removeMessage(self: *const Database, filename: [:0]const u8) Error!void {
    try wrap(c.notmuch_database_remove_message(self.database, filename));
}

pub fn getDefaultIndexOpts(self: *const Database) ?IndexOpts {
    return .{
        .indexopts = c.notmuch_database_get_default_indexopts(self.database) orelse return null,
    };
}

///
pub fn configPath(self: *const Database) ?[:0]const u8 {
    const config = c.notmuch_config_path(self.database);
    return std.mem.span(config orelse return null);
}

/// get a configuration value from an open database.
///
/// This value reflects all configuration information given at the time
/// the database was opened.
///
/// Returns NULL if 'key' unknown or if no value is known for 'key'.
/// Otherwise returns a string owned by notmuch which should not be modified
/// nor freed by the caller.
pub fn configGet(self: *const Database, key: CONFIG) Error!?[:0]const u8 {
    return std.mem.span(c.notmuch_config_get(self.database, @intFromEnum(key)) orelse return null);
}

/// set a configuration value
pub fn configSet(self: *const Database, key: CONFIG, value: [:0]const u8) Error!void {
    try wrap(c.notmuch_config_set(self.database, @intFromEnum(key), value));
}

/// Returns an iterator for a ';'-delimited list of configuration values
///
/// These values reflect all configuration information given at the
/// time the database was opened.
pub fn configGetValues(
    self: *const Database,
    /// configuration key
    key: CONFIG,
) ValuesIterator {
    return .{
        .values = c.notmuch_config_get_values(self.database, @intFromEnum(key)),
    };
}

/// Get a configuration value from an open database as boolean.
///
/// This value reflects all configuration information given at the time the
/// database was opened.
///
/// Returns IllegalArgument error if either key is unknown or the
/// corresponding value does not convert to boolean.
pub fn configGetBool(
    /// the database
    self: *const Database,
    /// configuration key
    key: CONFIG,
) Error!bool {
    var value: c.notmuch_bool_t = undefined;
    try wrap(c.notmuch_config_get_bool(self.database, @intFromEnum(key), &value));
    return value != 0;
}

/// Returns an iterator for a ';'-delimited list of configuration values
///
/// These values reflect all configuration information given at the
/// time the database was opened.
pub fn configGetValuesString(
    self: *const Database,
    /// configuration key
    key: CONFIG,
) ValuesIterator {
    return .{
        .values = c.notmuch_config_get_values_string(self.database, @intFromEnum(key)),
    };
}

/// Create a new query for 'database'.
///
/// Here, 'database' should be an open database, (see `open` and `create`).
///
/// For the query string, we'll document the syntax here more completely in the
/// future, but it's likely to be a specialized version of the general Xapian
/// query syntax:
///
/// https://xapian.org/docs/queryparser.html
///
/// As a special case, passing either a length-zero string, (that is ""), or a
/// string consisting of a single asterisk (that is "*"), will result in a query
/// that returns all messages in the database.
///
/// See `Query.setSort` for controlling the order of results. See
/// `Query.searchMessages` and `Query.searchThreads` to actually execute the
/// query.
pub fn queryCreate(self: *const Database, query_string: [:0]const u8) Error!Query {
    return .{
        .query = c.notmuch_query_create(self.database, query_string) orelse return error.OutOfMemory,
    };
}

pub fn queryCreateWithSyntax(self: *const Database, query_string: [:0]const u8, syntax: QUERY_SYNTAX) Error!Query {
    var query: ?*c.notmuch_query_t = undefined;

    try wrap(c.notmuch_query_create_with_syntax(self.database, query_string, @intFromEnum(syntax), &query));

    return .{
        .query = query orelse return error.OutOfMemory,
    };
}

pub const IndexOpts = struct {
    indexopts: *c.notmuch_indexopts_t,

    pub fn getDecryptPolicy(self: IndexOpts) DECRYPT {
        return @enumFromInt(c.notmuch_indexopts_get_decrypt_policy(self.indexopts));
    }

    pub fn setDecryptPolicy(self: IndexOpts, decrypt_policy: DECRYPT) Error!void {
        try wrap(c.notmuch_indexopts_set_decrypt_policy(self.indexopts, @intFromEnum(decrypt_policy)));
    }

    pub fn deinit(self: IndexOpts) void {
        c.notmuch_indexopts_destroy(self.indexopts);
    }
};

pub const ValuesIterator = struct {
    values: ?*c.notmuch_config_values_t,

    pub fn next(self: *ValuesIterator) ?[:0]const u8 {
        const values = self.values orelse return null;
        if (c.notmuch_config_values_valid(values) == 0) return null;
        defer c.notmuch_config_values_move_to_next(values);
        return std.mem.span(c.notmuch_config_values_get(values) orelse unreachable);
    }

    pub fn start(self: *ValuesIterator) void {
        const values = self.values orelse return;
        c.notmuch_config_values_start(values);
    }

    pub fn deinit(self: *ValuesIterator) void {
        const values = self.values orelse return;
        c.notmuch_config_values_destroy(values);
    }
};

pub const PairsIterator = struct {
    pairs: ?*c.notmuch_config_pairs_t,

    pub const Pair = struct {
        key: [:0]const u8,
        value: [:0]const u8,
    };

    pub fn next(self: *PairsIterator) ?Pair {
        const pairs = self.pairs orelse return null;
        if (c.notmuch_config_pairs_valid(pairs) == 0) return null;
        defer c.notmuch_config_pairs_move_to_next(pairs);
        return .{
            .key = std.mem.span(c.notmuch_config_pairs_key(pairs) orelse unreachable),
            .value = std.mem.span(c.notmuch_config_pairs_value(pairs) orelse unreachable),
        };
    }

    pub fn deinit(self: *PairsIterator) void {
        const pairs = self.pairs orelse return;
        c.notmuch_config_pairs_destroy(pairs);
    }
};
