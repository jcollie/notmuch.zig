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
pub const Config = enums.Config;
pub const Mode = enums.DatabaseMode;
const Decrypt = enums.DECRYPT;
const QuerySyntax = enums.QuerySyntax;
const STATUS = enums.Status;
const status = enums.status;

const Directory = @import("Directory.zig");
const Message = @import("Message.zig");
const Query = @import("Query.zig");
const TagsIterator = @import("TagsIterator.zig");

/// A callback invoked by `compact` to notify the user of the progress of the
/// compaction process.
pub const StatusCallback = fn (message: [*c]const u8, closure: ?*anyopaque) callconv(.c) void;

database: *c.notmuch_database_t,

pub const OpenCreateOptions = struct {
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
    NotmuchVersion,
    OutOfMemory,
    FileError,
    XapianException,
};

pub const OpenResult = union(enum) {
    ok: Database,
    err: struct {
        err: OpenError,
        msg: [*c]u8,

        pub fn message(self: @This()) ?[:0]const u8 {
            return std.mem.span(self.msg orelse return null);
        }

        pub fn deinit(self: @This()) void {
            c.free(@ptrCast(@constCast(self.msg)));
        }
    },
};

/// Open an existing notmuch database located at `database_path`, using
/// configuration in `config_path`.
pub fn open(mode: Mode, options: OpenCreateOptions) OpenResult {
    if (!c.LIBNOTMUCH_CHECK_VERSION(5, 6, 0)) {
        return .{
            .err = .{
                .err = error.NotmuchVersion,
                .msg = null,
            },
        };
    }

    var message: [*c]u8 = null;

    var database: ?*c.notmuch_database_t = null;

    const err = switch (status(c.notmuch_database_open_with_config(
        options.database_path orelse null,
        @intFromEnum(mode),
        options.config_path orelse null,
        options.profile orelse null,
        &database,
        &message,
    ))) {
        .success => {
            return .{
                .ok = .{
                    .database = database orelse unreachable,
                },
            };
        },
        .file_error => error.FileError,
        .no_config => error.NoConfig,
        .null_pointer => error.NullPointer,
        .out_of_memory => error.OutOfMemory,
        .xapian_exception => error.XapianException,
        else => unreachable,
    };

    return .{
        .err = .{
            .err = err,
            .msg = message,
        },
    };
}

pub const CreateError = error{
    DatabaseExists,
    FileError,
    NoConfig,
    NotmuchVersion,
    OutOfMemory,
    XapianException,
};

pub const CreateResult = union(enum) {
    ok: Database,
    err: struct {
        err: CreateError,
        msg: [*c]u8,

        pub fn message(self: @This()) ?[:0]const u8 {
            return std.mem.span(self.msg orelse return null);
        }

        pub fn deinit(self: @This()) void {
            c.free(@ptrCast(@constCast(self.msg)));
        }
    },
};

/// Create a new notmuch database.
pub fn create(options: OpenCreateOptions) CreateResult {
    if (!c.LIBNOTMUCH_CHECK_VERSION(5, 6, 0)) {
        return .{
            .err = .{
                .err = error.NotmuchVersion,
                .msg = null,
            },
        };
    }

    var message: [*c]u8 = null;

    var database: ?*c.notmuch_database_t = null;

    const err = switch (status(c.notmuch_database_create_with_config(
        options.database_path orelse null,
        options.config_path orelse null,
        options.profile orelse null,
        &database,
        &message,
    ))) {
        .success => {
            return .{
                .ok = .{
                    .database = database orelse unreachable,
                },
            };
        },
        .database_exists => error.DatabaseExists,
        .file_error => error.FileError,
        .no_config => error.NoConfig,
        .out_of_memory => error.OutOfMemory,
        .xapian_exception => error.XapianException,
        else => |v| {
            std.debug.print("{t}\n", .{v});
            unreachable;
        },
    };

    return .{
        .err = .{
            .err = err,
            .msg = message,
        },
    };
}

test create {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});

    try tmp.dir.createDir(io, "mail", .default_dir);
    try tmp.dir.createDir(io, "mail/cur", .default_dir);
    try tmp.dir.createDir(io, "mail/new", .default_dir);
    try tmp.dir.createDir(io, "mail/tmp", .default_dir);

    const config_path = cfg: {
        var dir_name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(std.testing.io, &dir_name_buf);
        const dir_name = dir_name_buf[0..len];

        const database_path = try std.fs.path.joinZ(alloc, &.{ dir_name, "mail" });
        defer alloc.free(database_path);

        var cfg = try tmp.dir.createFile(io, "config", .{});
        defer cfg.close(io);

        var buf: [64]u8 = undefined;
        var file_writer = cfg.writer(io, &buf);
        const writer = &file_writer.interface;

        try writer.print(
            \\[database]
            \\path={s}
            \\mail_root={s}
            \\[user]
            \\primary_email=zig@example.org
            \\[new]
            \\[search]
            \\[maildir]
            \\
        ,
            .{
                database_path,
                database_path,
            },
        );
        try writer.flush();

        break :cfg try std.fs.path.joinZ(alloc, &.{ dir_name, "config" });
    };
    defer alloc.free(config_path);

    const r = create(.{ .config_path = config_path });
    defer switch (r) {
        .ok => |db| db.destroy() catch {},
        .err => |e| e.deinit(),
    };
    try std.testing.expect(r == .ok);
}

pub const CloseError = error{XapianException};

/// Commit changes and close the given notmuch database.
///
/// After `close` has been called, calls to other functions on
/// objects derived from this database may either behave as if the database had
/// not been closed (e.g., if the required data has been cached) or may fail
/// with a NOTMUCH_STATUS_XAPIAN_EXCEPTION. The only further operation permitted
/// on the database itself is to call notmuch_database_destroy.
///
/// `close` can be called multiple times. Later calls have no
/// effect.
///
/// For writable databases, `close` commits all changes to disk before closing
/// the database, unless the caller is currently in an atomic section (there was
/// a `beginAtomic` without a matching `endAtomic`). In this case changes since
/// the last commit are discarded. See `endAtomic` for more information.
pub fn close(self: *const Database) CloseError!void {
    switch (status(c.notmuch_database_close(self.database))) {
        .success => {},
        .xapian_exception => return error.XapianException,
        else => unreachable,
    }
}
/// Compact the notmuch database, backing up the original database to the given
/// path.
///
/// If the optional callback function `status_cb` is non-`null`, it will be
/// called with diagnostic and informational messages. The argument `closure` is
/// passed verbatim to any callback invoked.
pub fn compact(self: *const Database, backup_path: [:0]const u8, status_cb: ?StatusCallback, closure: ?*anyopaque) Error!void {
    try wrap(c.notmuch_database_compact_db(self.database, backup_path, status_cb, closure));
}

/// Destroy the notmuch database, closing it if necessary and freeing all
/// associated resources.
///
/// Return value as in `close` if the database was open; `destroy` itself has no
/// failure modes.
pub fn destroy(self: *const Database) Error!void {
    switch (status(c.notmuch_database_destroy(self.database))) {
        .success => {},
        .xapian_exception => return error.XapianException,
        else => unreachable,
    }
}

/// Return the database path of the database.
///
/// The return value is a string owned by `notmuch` so should not be modified
/// nor freed by the caller.
pub fn getPath(self: *const Database) ?[:0]const u8 {
    return std.mem.span(c.notmuch_database_get_path(self.database) orelse return null);
}

/// Return the database format version of the database.
pub fn getVersion(self: *const Database) error{FormatVersionError}!u32 {
    const version = c.notmuch_database_get_version(self.database);
    if (version == 0) return error.FormatVersionError;
    return version;
}

/// Can the database be upgraded to a newer database version?
///
/// If this function returns `true`, then the caller may call `upgrade`
/// to upgrade the database. If the caller does not upgrade an out-of-date
/// database, then some functions may fail with `UpgradeRequired`. This always
/// returns `false` for a read-only database because there's no way to upgrade a
/// read-only database.
///
/// Also returns `false` if an error occurs accessing the database.
pub fn needsUpgrade(self: *const Database) bool {
    return c.notmuch_database_needs_upgrade(self.database) != 0;
}

pub const UpgradeProgressNotifyCallback = fn (closure: ?*anyopaque, progress: f64) callconv(.c) void;

/// Upgrade the current database to the latest supported version.
///
/// This ensures that all current notmuch functionality will be available
/// on the database. After opening a database in read-write mode, it is
/// recommended that clients check if an upgrade is needed (`needsUpgrade`)
/// and if so, upgrade with this function before making any modifications. If
/// `needsUpgrade` returns `false`, this will be a no-op.
///
/// The optional `progress_notify` callback can be used by the caller to
/// provide progress indication to the user. If non-`null` it will be called
/// periodically with `progress` as a floating-point value in the range of [0.0
/// .. 1.0] indicating the progress made so far in the upgrade process. The
/// argument `closure` is passed verbatim to any callback invoked.
pub fn upgrade(self: *const Database, progress_notify: ?UpgradeProgressNotifyCallback, closure: ?*anyopaque) Error!void {
    try wrap(c.notmuch_database_upgrade(self.database, progress_notify, closure));
}

/// Begin an atomic database operation.
///
/// Any modifications performed between a successful `beginAtomic` and a
/// `endAtomic` will be applied to the database atomically. Note that, unlike a
/// typical database transaction, this only ensures atomicity, not durability;
/// neither `beginAtomic` nor `endAtomic` necessarily flush modifications to
/// disk.
///
/// Atomic sections may be nested. `beginAtomic` and `endAtomic` must always be
/// called in pairs.
pub fn beginAtomic(self: *const Database) error{XapianException}!void {
    switch (status(c.notmuch_database_begin_atomic(self.database))) {
        .success => {},
        .xapian_exception => return error.XapianException,
        else => unreachable,
    }
}

/// Indicate the end of an atomic database operation. If repeated (with matching
/// `beginAtomic`) "database.autocommit" times, commit the the transaction and
/// all previous (non-cancelled) transactions to the database.
pub fn endAtomic(self: *const Database) error{ UnbalancedAtomic, XapianException }!void {
    switch (status(c.notmuch_database_begin_atomic(self.database))) {
        .success => {},
        .unbalanced_atomic => return error.UnbalancedAtomic,
        .xapian_exception => return error.XapianException,
        else => unreachable,
    }
}

pub const Revision = struct {
    /// The database revision number increases monotonically with each commit
    /// to the database. Hence, all messages and message changes committed
    /// to the database (that is, visible to readers) have a last modification
    /// revision <= the committed database revision. Any messages committed
    /// in the future will be assigned a modification revision > the committed
    /// database revision.
    revision: u64,
    /// The UUID is an opaque string that uniquely identifies this database.
    /// Two revision numbers are only comparable if they have the same database
    /// UUID. The string `uuid` is owned by notmuch and should not be freed or
    /// modified by the user.
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
/// The string `uuid` is owned by notmuch and should not be freed or modified by
/// the user.
pub fn getRevision(self: *const Database) Revision {
    var uuid: [*c]const u8 = undefined;
    const revision = c.notmuch_database_get_revision(self.database, &uuid);
    return .{
        .revision = revision,
        .uuid = std.mem.span(uuid),
    };
}

/// Retrieve a directory object from the database for `path`.
///
/// Here, 'path' should be a path relative to the path of `database` (see
/// `getPath`), or else should be an absolute path with initial components that
/// match the path of `database`.
///
/// If this directory object does not exist in the database, this returns
/// `null`.
///
/// Otherwise the returned directory object is owned by the database and as
/// such, will only be valid until `destroy` is called.
pub fn getDirectory(self: *const Database, path: [:0]const u8) Error!?Directory {
    var directory: ?*c.notmuch_directory_t = null;

    return switch (status(c.notmuch_database_get_directory(self.database, path, &directory))) {
        .success => .{
            .directory = directory orelse return null,
        },
        .null_pointer => error.NullPointer,
        .upgrade_required => error.UpgradeRequired,
        .xapian_exception => error.XapianException,
        else => unreachable,
    };
}

pub const IndexFileError = error{
    /// An error occurred trying to open the file, (such as permission denied, or
    /// file not found, etc.). Nothing added to the database.
    FileError,
    /// The contents of filename don't look like an email message. Nothing added
    /// to the database.
    FileNotEmail,
    /// Database was opened in read-only mode so no message can be added.
    ReadOnlyDatabase,
    /// The caller must upgrade the database to use this function.
    UpgradeRequired,
};

/// Add a message file to a database, indexing it for retrieval by future
/// searches.  If a message already exists with the same message ID as the
/// specified file, their indexes will be merged, and this new filename will
/// also be associated with the existing message.
///
/// Here, `filename` should be a path relative to the path of `database` (see
/// `getPath`), or else should be an absolute filename with initial components
/// that match the path of `database`.
///
/// The file should be a single mail message (not a multi-message mbox) that is
/// expected to remain at its current location, (since the notmuch database will
/// reference the filename, and will not copy the entire contents of the file.
///
/// If another message with the same message ID already exists in the database,
/// rather than creating a new message, this adds the search terms from the
/// identified file to the existing message's index, and adds `filename` to the
/// list of filenames known for the message.
///
/// The `indexopts` parameter can be `null` (meaning, use the indexing
/// defaults from the database), or can be an explicit choice of
/// indexing options that should govern the indexing of this specific
/// `filename`.
///
/// Note that this does not synchronise Maildir flags to notmuch flags,
/// regardless of the value of `maildir.synchronize_flags`. Future calls to
/// notmuch-new(1) will also not synchronise flags, since the file's current
/// mtime shall be recorded as indexed. If flags ought to be synchronised,
/// explicitly call notmuch_message_maildir_flags_to_tags.
pub fn indexFile(self: *const Database, filename: [:0]const u8, indexopts: ?IndexOpts) IndexFileError!void {
    return switch (status(c.notmuch_database_index_file(
        self.database,
        filename,
        if (indexopts) |i| i.indexopts else null,
        null,
    ))) {
        .success => {},
        .duplicate_message_id => {},
        .file_error => error.FileError,
        .file_not_email => error.FileNotEmail,
        .read_only_database => error.ReadOnlyDatabase,
        .upgrade_required => error.UpgradeRequired,
        else => unreachable,
    };
}

/// Add a message file to a database, indexing it for retrieval by future
/// searches, and return a message object. If a message already exists with the
/// same message ID as the specified file, their indexes will be merged, and
/// this new filename will also be associated with the existing message.
///
/// Here, `filename` should be a path relative to the path of `database` (see
/// `getPath`), or else should be an absolute filename with initial components
/// that match the path of `database`.
///
/// The file should be a single mail message (not a multi-message mbox) that is
/// expected to remain at its current location, (since the notmuch database will
/// reference the filename, and will not copy the entire contents of the file.
///
/// If another message with the same message ID already exists in the database,
/// rather than creating a new message, this adds the search terms from the
/// identified file to the existing message's index, and adds `filename` to the
/// list of filenames known for the message.
///
/// The `indexopts` parameter can be `null` (meaning, use the indexing
/// defaults from the database), or can be an explicit choice of
/// indexing options that should govern the indexing of this specific
/// `filename`.
///
/// On successful return, a message object will be returned that can be used for
/// things such as adding tags to the just-added message. The user should call
/// `Message.destroy` when done with the message.
///
/// Note that this does not synchronise Maildir flags to notmuch flags,
/// regardless of the value of maildir.synchronize_flags. Future calls to
/// notmuch-new(1) will also not synchronise flags, since the file's current
/// mtime shall be recorded as indexed. If flags ought to be synchronised,
/// explicitly call notmuch_message_maildir_flags_to_tags.
pub fn indexFileGetMessage(self: *const Database, filename: [:0]const u8, indexopts: ?IndexOpts) Error!Message {
    var message: ?*c.notmuch_message_t = null;
    return switch (status(c.notmuch_database_index_file(
        self.database,
        filename,
        if (indexopts) |i| i.indexopts else null,
        &message,
    ))) {
        .success => .{
            .duplicate = false,
            .message = message orelse unreachable,
        },
        .duplicate_message_id => .{
            .duplicate = true,
            .message = message orelse unreachable,
        },
        .file_error => error.FileError,
        .file_not_email => error.FileNotEmail,
        .read_only_database => error.ReadOnlyDatabase,
        .upgrade_required => error.UpgradeRequired,
        else => unreachable,
    };
}

pub const RemoveMessageError = error{
    /// This filename was removed but the message persists in the database with at
    /// least one other filename.
    DuplicateMessageID,
    /// Database was opened in read-only mode so no message can be removed.
    ReadOnlyDatabase,
    /// The caller must upgrade the database to use this function.
    UpgradeRequired,
    /// A Xapian exception occurred, message not removed.
    XapianException,
};

/// Remove a message filename from the given notmuch database. If the message
/// has no more filenames, remove the message.
///
/// If the same message (as determined by the message ID) is still available
/// via other filenames, then the message will persist in the database for those
/// filenames. When the last filename is removed for a particular message, the
/// database content for that message will be entirely removed.
pub fn removeMessage(self: *const Database, filename: [:0]const u8) RemoveMessageError!void {
    return switch (status(c.notmuch_database_remove_message(self.database, filename))) {
        .success => {},
        .duplicate_message_id => error.DuplicateMessageID,
        .read_only_database => error.ReadOnlyDatabase,
        .upgrade_required => error.UpgradeRequired,
        .xapian_exception => error.XapianException,
        else => unreachable,
    };
}

pub const FindMessageError = error{
    /// Out of memory creating message object.
    OutOfMemory,
    /// A Xapian exception occurred.
    XapianException,
};

/// Find a message with the given message ID.
///
/// If a message with the given message ID is found then a message object
/// will be returned. The caller should call `Message.deinit` when done with
/// the message.
///
/// If a message with the given message ID is not found then `null` is
/// returned.
pub fn findMessage(self: *const Database, message_id: [:0]const u8) FindMessageError!?Message {
    var message: ?*c.notmuch_message_t = null;
    return switch (status(c.notmuch_database_find_message(self.database, message_id, &message))) {
        .success => .{
            .message = message orelse return null,
        },
        .null_pointer => unreachable,
        .out_of_memory => error.OutOfMemory,
        .xapian_exception => error.XapianException,
        else => unreachable,
    };
}
/// Find a message with the given filename.
///
/// If the database contains a message with the given filename then a message
/// object is returned. The caller should call `Message.deinit` when done with
/// the message.
///
/// If a message with the given filename is not found then `null` is
/// returned.
pub fn findMessageByFilename(self: *const Database, filename: [:0]const u8) FindMessageError!?Message {
    var message: ?*c.notmuch_message_t = null;
    return switch (status(c.notmuch_database_find_message_by_filename(self.database, filename, &message))) {
        .success => .{
            .message = message orelse return null,
        },
        .null_pointer => unreachable,
        .out_of_memory => error.OutOfMemory,
        .xapian_exception => error.XapianException,
        else => unreachable,
    };
}

/// Return a list of all tags found in the database.
///
/// This function creates a list of all tags found in the database. The
/// resulting list contains all tags from all messages found in the database.
///
/// On error this function returns `null`.
pub fn getAllTags(self: *const Database) ?TagsIterator {
    return .{
        .tags = c.notmuch_database_get_all_tags(self.database) orelse return null,
    };
}

pub const ReopenError = error{
    /// The database was not open.
    IllegalArgument,
    /// A Xapian exception occurred.
    XapianException,
};

/// Reopen an open notmuch database.
pub fn reopen(self: *Database, mode: Mode) ReopenError!void {
    return switch (status(c.notmuch_database_reopen(self.database, @intFromEnum(mode)))) {
        .success => {},
        .illegal_argument => error.IllegalArgument,
        .xapian_exception => error.XapianException,
        else => unreachable,
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
pub fn queryCreate(self: *const Database, query_string: [:0]const u8) error{OutOfMemory}!Query {
    return .init(c.notmuch_query_create(self.database, query_string) orelse return error.OutOfMemory);
}

/// Create a new query.
///
/// For the query string, we'll document the syntax here more completely in the
/// future, but it's likely to be a specialized version of the general Xapian
/// query syntax:
///
/// https://xapian.org/docs/queryparser.html
///
/// As a special case, passing either a length-zero string, (that is `""`), or
/// a string consisting of a single asterisk (that is `"*"`), will result in a
/// query that returns all messages in the database.
///
/// See `Query.setSort` for controlling the order of results. See
/// `Query.searchMessages` and `Query.searchThreads` to actually execute the
/// query.
///
/// User should call `Query.deinit` when finished with this query.
pub fn queryCreateWithSyntax(self: *const Database, query_string: [:0]const u8, syntax: QuerySyntax) Error!Query {
    var query: ?*c.notmuch_query_t = undefined;

    try wrap(c.notmuch_query_create_with_syntax(self.database, query_string, @intFromEnum(syntax), &query));

    return .init(query orelse return error.OutOfMemory);
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

pub const IndexOpts = struct {
    indexopts: *c.notmuch_indexopts_t,

    pub fn getDecryptPolicy(self: IndexOpts) Decrypt {
        return @enumFromInt(c.notmuch_indexopts_get_decrypt_policy(self.indexopts));
    }

    pub fn setDecryptPolicy(self: IndexOpts, decrypt_policy: Decrypt) Error!void {
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

test {
    std.testing.refAllDecls(@This());
}
