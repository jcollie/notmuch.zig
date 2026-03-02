// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Zig wrapper around the `notmuch` database APIs.

const Database = @This();

const std = @import("std");
const log = std.log.scoped(.notmuch);

const c = @import("c");

const Error = @import("error.zig").Error;
const wrap = @import("error.zig").wrap;
const wrapMessage = @import("error.zig").wrapMessage;

const enums = @import("enums.zig");
pub const Config = enums.CONFIG;
pub const Mode = enums.DATABASE_MODE;
const DECRYPT = enums.DECRYPT;
const QUERY_SYNTAX = enums.QUERY_SYNTAX;
const STATUS = enums.STATUS;
const status = enums.status;

const Message = @import("Message.zig");
const Query = @import("Query.zig");

database: *c.notmuch_database_t,

pub const OpenOptions = struct {
    /// Path to config file.
    ///
    /// Config file is key-value, with mandatory sections. See
    /// **notmuch-config(5)** for more information. The key-value pair
    /// overrides the corresponding configuration data stored in the
    /// database (see <em>notmuch_database_get_config</em>)
    ///
    /// If `config_path` is `null` use the path specified
    ///
    /// - in environment variable `NOTMUCH_CONFIG`, if non-empty
    ///
    /// - by  `XDG_CONFIG_HOME`/notmuch/ where
    ///   `XDG_CONFIG_HOME` defaults to `$HOME/.config`.
    ///
    /// - by `$HOME/.notmuch-config`
    ///
    /// If `config_path` is "" (empty string) then do not
    /// open any configuration file.
    config_path: ?[:0]const u8 = null,
    /// Path to existing database.
    ///
    /// A notmuch database is a Xapian database containing appropriate
    /// metadata.
    ///
    /// The database should have been created at some time in the past,
    /// (not necessarily by this process), by calling
    /// notmuch_database_create.
    ///
    /// If 'database_path' is NULL, use the location specified
    ///
    /// - in the environment variable NOTMUCH_DATABASE, if non-empty
    ///
    /// - in a configuration file, located as described under 'config_path'
    ///
    /// - by $XDG_DATA_HOME/notmuch/$PROFILE where XDG_DATA_HOME defaults
    ///   to "$HOME/.local/share" and PROFILE as as discussed in
    ///   'profile'
    ///
    /// If 'database_path' is non-NULL, but does not appear to be a Xapian
    /// database, check for a directory '.notmuch/xapian' below
    /// 'database_path' (this is the behavior of
    /// notmuch_database_open_verbose pre-0.32).
    database_path: ?[*:0]const u8 = null,
    /// Name of profile (configuration/database variant).
    ///
    /// If non-`null`, append to the directory / file path determined for
    /// <em>config_path</em> and <em>database_path</em>.
    ///
    /// If `null` then use
    /// - environment variable `NOTMUCH_PROFILE` if defined,
    /// - otherwise `"default"` for directories and `""` (empty string) for paths.
    profile: ?[:0]const u8 = null,
};

pub const OpenError = error{
    NullPointer,
    NoConfig,
    OutOfMemory,
    FileError,
    XapianException,
};

/// Open an existing notmuch database located at `database_path`, using
/// configuration in `config_path`.
pub fn open(mode: Mode, options: OpenOptions) OpenError!Database {
    if (!c.LIBNOTMUCH_CHECK_VERSION(5, 6, 0)) {
        return error.NotmuchVersion;
    }

    var error_message: [*c]u8 = null;
    defer if (error_message) |m| c.free(m);

    var database: ?*c.notmuch_database_t = null;

    switch (status(c.notmuch_database_open_with_config(
        options.database_path,
        @intFromEnum(mode),
        options.config_path,
        options.profile,
        &database,
        &error_message,
    ), error_message)) {
        .success => {},
        .null_pointer => return error.NullPointer,
        .NO_CONFIG => return error.NoConfig,
        .out_of_memory => return error.OutOfMemory,
        .file_error => return error.FileError,
        .xapian_exception => return error.XapianException,
    }

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

/// Begin an atomic database operation.
///
/// Any modifications performed between a successful begin and a
/// notmuch_database_end_atomic will be applied to the database atomically.
/// Note that, unlike a typical database transaction, this only ensures
/// atomicity, not durability; neither begin nor end necessarily flush
/// modifications to disk.
///
/// Atomic sections may be nested. begin_atomic and end_atomic must always be
/// called in pairs.
pub fn beginAtomic(self: *const Database) error{XapianException}!void {
    switch (status(c.notmuch_database_begin_atomic(self.database))) {
        .success => {},
        .xapian_exception => return error.XapianException,
        else => unreachable,
    }
}

/// Indicate the end of an atomic database operation. If repeated (with matching
/// notmuch_database_begin_atomic) "database.autocommit" times, commit the the
/// transaction and all previous (non-cancelled) transactions to the database.
pub fn endAtomic(self: *const Database) error{ UnbalancedAtomic, XapianException }!void {
    switch (status(c.notmuch_database_begin_atomic(self.database))) {
        .success => {},
        .unbalanced_atomic => return error.UnbalancedAtomic,
        .xapian_exception => return error.XapianException,
        else => unreachable,
    }
}

pub const Revision = struct {
    revision: u64,
    uuid: []const u8,

    pub fn compare(self: Revision, other: Revision) error{DatabaseMismatch}!enum { lt, eq, gt } {
        if (!std.mem.eql(u8, self.uuid, other.uuid)) return error.DatabaseMismatch;
        if (self.revision < other.revision) return .lt;
        if (self.revision > other.revision) return .gt;
        return .eq;
    }
};

/// Return the committed database revision and UUID.
///
/// The database revision number increases monotonically with each commit to the
/// database. Hence, all messages and message changes committed to the database
/// (that is, visible to readers) have a last modification revision <= the
/// committed database revision. Any messages committed in the future will be
/// assigned a modification revision > the committed database revision.
///
/// The UUID is a opaque string that uniquely identifies this database. Two
/// revision numbers are only comparable if they have the same database UUID.
/// The string 'uuid' is owned by notmuch and should not be freed or modified by
/// the user.
pub fn getRevision(self: *const Database) Revision {
    var uuid: [*c]const u8 = undefined;
    const revision = c.notmuch_database_get_revision(self.database, &uuid);
    return .{
        .revision = revision,
        .uuid = std.mem.span(uuid),
    };
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
pub fn configGet(self: *const Database, key: Config) Error!?[:0]const u8 {
    return std.mem.span(c.notmuch_config_get(self.database, @intFromEnum(key)) orelse return null);
}

/// Set a configuration value
pub fn configSet(self: *const Database, key: Config, value: [:0]const u8) Error!void {
    try wrap(c.notmuch_config_set(self.database, @intFromEnum(key), value));
}

/// Returns an iterator for a `;`-delimited list of configuration values.
///
/// These values reflect all configuration information given at the
/// time the database was opened.
pub fn configGetValues(
    self: *const Database,
    /// configuration key
    key: Config,
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
    key: Config,
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
    key: Config,
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
