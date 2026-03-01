// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: MIT

const Database = @This();

const std = @import("std");
const log = std.log.scoped(.notmuch);

const c = @import("c");

const Error = @import("error.zig").Error;
const wrap = @import("error.zig").wrap;
const wrapMessage = @import("error.zig").wrapMessage;

const enums = @import("enums.zig");
const CONFIG = enums.CONFIG;
const DATABASE_MODE = enums.DATABASE_MODE;
const DECRYPT = enums.DECRYPT;
const QUERY_SYNTAX = enums.QUERY_SYNTAX;

const Message = @import("Message.zig");
const Query = @import("Query.zig");

database: *c.notmuch_database_t,

pub const OpenOptions = struct {
    /// Specify a config file.
    config_path: ?[:0]const u8 = null,
    /// Specify a database path.
    database_path: ?[*:0]const u8 = null,
    /// Specify a profile.
    profile: ?[:0]const u8 = null,
};

/// Open an existing notmuch database.
pub fn open(mode: DATABASE_MODE, options: OpenOptions) Error!Database {
    if (!c.LIBNOTMUCH_CHECK_VERSION(5, 6, 0)) {
        return error.NotmuchVersion;
    }

    var error_message: [*c]u8 = null;
    var database: ?*c.notmuch_database_t = null;
    try wrapMessage(c.notmuch_database_open_with_config(
        options.database_path,
        @intFromEnum(mode),
        options.config_path,
        options.profile,
        &database,
        &error_message,
    ), error_message);
    return .{
        .database = database orelse unreachable,
    };
}

pub const CreateOptions = struct {
    /// Specify a config file.
    config_path: ?[:0]const u8 = null,
    /// Specify a database path.
    database_path: ?[*:0]const u8 = null,
    /// Specify a profile.
    profile: ?[:0]const u8 = null,
};

/// Create a new notmuch database.
pub fn create(options: CreateOptions) Error!Database {
    if (!c.LIBNOTMUCH_CHECK_VERSION(5, 6, 0)) {
        return error.NotmuchVersion;
    }

    var error_message: [*c]u8 = null;
    var database: ?*c.notmuch_database_t = null;
    try wrapMessage(
        c.notmuch_database_create_with_config(
            options.database_path,
            options.config_path,
            options.profile,
            &database,
            &error_message,
        ),
        error_message,
    );
    return .{
        .database = database orelse unreachable,
    };
}

/// Close the database.
pub fn close(self: *const Database) void {
    _ = c.notmuch_database_close(self.database);
}

/// Destroy the notmuch database, closing it if necessary and freeing all
/// associated resources.
///
/// Return value as in notmuch_database_close if the database was open;
/// notmuch_database_destroy itself has no failure modes.
pub fn destroy(self: *const Database) Error!void {
    try wrap(c.notmuch_database_destroy(self.database));
}

pub fn indexFile(self: *const Database, filename: [:0]const u8, indexopts: ?IndexOpts) Error!void {
    try wrap(c.notmuch_database_index_file(
        self.database,
        filename,
        if (indexopts) |i| i.indexopts else null,
        null,
    ));
}

/// A callback invoked by Database.compact to notify the user of the
/// progress of the compaction process.
pub const StatusCallback = fn (message: [*c]const u8, closure: ?*anyopaque) callconv(.c) void;

/// Compact a notmuch database, backing up the original database to the given
/// path.
///
/// The database will be opened in read-write mode during the compaction process
/// to ensure no writes are made.
///
/// If the optional callback function `status_cb` is non-`null`, it will be
/// called with diagnostic and informational messages. The argument `closure` is
/// passed verbatim to any callback invoked.
pub fn compact(path: [:0]const u8, backup_path: [:0]const u8, status_cb: ?StatusCallback, closure: ?*anyopaque) Error!void {
    try wrap(c.notmuch_database_compact(path, backup_path, status_cb, closure));
}

/// Return the database format version of the database.
pub fn getVersion(self: *const Database) error{FormatVersionError}!c_uint {
    const version = c.notmuch_database_get_version(self.database);
    if (version == 0) return error.FormatVersionError;
    return version;
}

/// Can the database be upgraded to a newer database version?
///
/// If this function returns TRUE, then the caller may call
/// notmuch_database_upgrade to upgrade the database. If the caller does
/// not upgrade an out-of-date database, then some functions may fail with
/// NOTMUCH_STATUS_UPGRADE_REQUIRED. This always returns FALSE for a read-only
/// database because there's no way to upgrade a read-only database.
///
/// Also returns FALSE if an error occurs accessing the database.
pub fn needsUpgrade(self: *const Database) bool {
    return c.notmuch_database_needs_upgrade(self.database) != 0;
}

pub const UpgradeProgressNotifyCallback = fn (closure: ?*anyopaque, progress: f64) callconv(.c) void;

/// Upgrade the current database to the latest supported version.
///
/// This ensures that all current notmuch functionality will be available on the
/// database. After opening a database in read-write mode, it is recommended
/// that clients check if an upgrade is needed (Database.needsUpgrade) and
/// if so, upgrade with this function before making any modifications. If
/// Database.needsUpgrade returns FALSE, this will be a no-op.
///
/// The optional `progress_notify` callback can be used by the caller to provide
/// progress indication to the user. If non-`null` it will be called periodically
/// with `progress` as a floating-point value in the range of [0.0 .. 1.0]
/// indicating the progress made so far in the upgrade process. The argument
/// `closure` is passed verbatim to any callback invoked.
pub fn upgrade(self: *const Database, progress_notify: ?UpgradeProgressNotifyCallback, closure: ?*anyopaque) Error!void {
    try wrap(c.notmuch_database_upgrade(self.database, progress_notify, closure));
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

/// Get a configuration value from an open database.
///
/// This value reflects all configuration information given at the time
/// the database was opened.
///
/// Returns `null` if `key` is unknown or if no value is known for `key`.
/// Otherwise returns a string owned by `notmuch` which should not be modified
/// nor freed by the caller.
pub fn configGet(self: *const Database, key: CONFIG) Error!?[:0]const u8 {
    return std.mem.span(c.notmuch_config_get(self.database, @intFromEnum(key)) orelse return null);
}

/// Set a configuration value
pub fn configSet(self: *const Database, key: CONFIG, value: [:0]const u8) Error!void {
    try wrap(c.notmuch_config_set(self.database, @intFromEnum(key), value));
}

/// Returns an iterator for a `;`-delimited list of configuration values.
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

/// Create a new query.
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
    return .init(c.notmuch_query_create(self.database, query_string) orelse return error.OutOfMemory);
}

pub fn queryCreateWithSyntax(self: *const Database, query_string: [:0]const u8, syntax: QUERY_SYNTAX) Error!Query {
    var query: ?*c.notmuch_query_t = undefined;

    try wrap(c.notmuch_query_create_with_syntax(self.database, query_string, @intFromEnum(syntax), &query));

    return .init(query orelse return error.OutOfMemory);
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
