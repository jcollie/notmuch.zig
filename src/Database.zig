// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! An open notmuch database.
//!
//! Obtain one with `open` or `create`; both return a tagged union carrying
//! either the database or an error along with libnotmuch's human-readable
//! message. A database supports searching via `queryCreate`, indexing and
//! removing mail files, message lookup by ID or filename, atomic sections,
//! configuration access, and maintenance operations such as `upgrade` and
//! `compact`. Call `deinit` to close and free the database when finished.

const Database = @This();

const std = @import("std");
const log = std.log.scoped(.notmuch);

const c = @import("c");

pub const Config = enums.Config;
pub const Mode = enums.DatabaseMode;

const Decrypt = enums.Decrypt;
const Directory = @import("Directory.zig");
const enums = @import("enums.zig");
const Error = @import("error.zig").Error;
const IndexOpts = @import("IndexOpts.zig");
const Message = @import("Message.zig");
const PairsIterator = @import("PairsIterator.zig");
const Query = @import("Query.zig");
const QuerySyntax = enums.QuerySyntax;
const status = enums.status;
const Status = enums.Status;
const TagsIterator = @import("TagsIterator.zig");
const ValuesIterator = @import("ValuesIterator.zig");
const wrap = @import("error.zig").wrap;
const wrapMessage = @import("error.zig").wrapMessage;

/// A callback invoked by `compact` to notify the user of the progress of the
/// compaction process.
pub const StatusCallback = *const fn (message: [*c]const u8, closure: ?*anyopaque) callconv(.c) void;

/// The underlying `notmuch_database_t` handle. Managed by `open`/`create`
/// and released by `deinit`; only needed directly when calling libnotmuch C
/// APIs these bindings do not wrap.
database: *c.notmuch_database_t,

pub const OpenCreateOptions = struct {
    /// Path to the configuration file.
    ///
    /// The configuration file is key-value, with mandatory sections; see
    /// **notmuch-config(5)** for more information. Its key-value pairs
    /// override the corresponding configuration data stored in the database
    /// (see `Database.configGet`).
    ///
    /// If `config_path` is `null`, use the path specified
    ///
    /// - in the environment variable `NOTMUCH_CONFIG`, if non-empty
    ///
    /// - by `$XDG_CONFIG_HOME/notmuch/` where `XDG_CONFIG_HOME` defaults to
    ///   `$HOME/.config`
    ///
    /// - by `$HOME/.notmuch-config`
    ///
    /// If `config_path` is `""` (the empty string), do not open any
    /// configuration file.
    config_path: ?[:0]const u8 = null,
    /// Path to the database.
    ///
    /// A notmuch database is a Xapian database containing appropriate
    /// metadata. For `open`, this is the path of an existing database,
    /// created at some time in the past (not necessarily by this process)
    /// with `Database.create`. For `create`, it is the path at which the new
    /// database will be created; creation fails with `error.DatabaseExists`
    /// if a database already exists there.
    ///
    /// If `database_path` is `null`, use the location specified
    ///
    /// - in the environment variable `NOTMUCH_DATABASE`, if non-empty
    ///
    /// - in a configuration file, located as described under `config_path`
    ///
    /// - by `$XDG_DATA_HOME/notmuch/$PROFILE` where `XDG_DATA_HOME` defaults
    ///   to `$HOME/.local/share` and `PROFILE` is as discussed in `profile`
    ///
    /// When opening, if `database_path` is non-`null` but does not appear to
    /// be a Xapian database, a directory `.notmuch/xapian` below
    /// `database_path` is checked as well (this is the behavior of
    /// `notmuch_database_open_verbose` pre-0.32).
    database_path: ?[:0]const u8 = null,
    /// Name of profile (configuration/database variant).
    ///
    /// If non-`null`, append to the directory / file path determined for
    /// `config_path` and `database_path`.
    ///
    /// If `null` then use
    /// - the environment variable `NOTMUCH_PROFILE` if defined,
    /// - otherwise `"default"` for directories and `""` (the empty string)
    ///   for paths.
    profile: ?[:0]const u8 = null,
};

pub const OpenError = error{
    /// libnotmuch reported a `null` pointer argument. The bindings always
    /// pass a valid output pointer, so this is not expected in practice.
    NullPointer,
    /// No configuration file was found. Fatal. Pass `""` as `config_path` to
    /// open the database without one.
    NoConfig,
    /// No database was found at `database_path` (or at the location
    /// determined from the environment and configuration).
    NoDatabase,
    /// libnotmuch is older than 5.6, the minimum version these bindings
    /// support. Reported by the bindings themselves, before calling into
    /// libnotmuch.
    NotmuchVersion,
    /// Out of memory.
    OutOfMemory,
    /// An error occurred trying to open the database or configuration file
    /// (such as permission denied, or file not found), or the database
    /// version is unknown.
    FileError,
    /// There is a problem with the supplied path, e.g. a relative path where
    /// an absolute path is required.
    PathError,
    /// A Xapian exception occurred.
    XapianException,
    /// libnotmuch returned an undocumented status code.
    Unexpected,
};

/// The result of `open`: either an open database or an error paired with
/// libnotmuch's human-readable message.
///
/// A tagged union is used instead of an error union because the message
/// accompanying a failure has to be retrieved and freed alongside the error;
/// call the `err` variant's `deinit` when done with it.
pub const OpenResult = union(enum) {
    /// The successfully opened database. The caller owns it and should call
    /// `Database.deinit` when finished with it.
    ok: Database,
    /// The failure, along with an optional message from libnotmuch.
    err: struct {
        /// The error corresponding to the status code libnotmuch returned.
        err: OpenError,
        /// The raw error message, if any. Use `message` to read it and
        /// `deinit` to free it.
        msg: [*c]u8,

        /// Return the human-readable error message from libnotmuch, or
        /// `null` if there is none. The string is owned by this result and
        /// is freed by `deinit`.
        pub fn message(self: @This()) ?[:0]const u8 {
            return std.mem.span(self.msg orelse return null);
        }

        /// Free the error message. Safe to call when there is no message.
        pub fn deinit(self: @This()) void {
            c.free(@ptrCast(@constCast(self.msg)));
        }
    },
};

/// Open an existing notmuch database located at `database_path`, using
/// configuration in `config_path`.
///
/// On success the caller owns the returned database and should call `deinit`
/// when finished with it. On failure the `err` variant carries the error and
/// an optional human-readable message; the caller should call its `deinit` to
/// free the message.
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
        @backingInt(mode),
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
        .no_database => error.NoDatabase,
        .null_pointer => error.NullPointer,
        .out_of_memory => error.OutOfMemory,
        .path_error => error.PathError,
        .xapian_exception => error.XapianException,
        else => error.Unexpected,
    };

    return .{
        .err = .{
            .err = err,
            .msg = message,
        },
    };
}

test open {
    const fixture = @import("testing.zig");

    const alloc = std.testing.allocator;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    // Close the writer so its changes are committed and visible to readers.
    const path = try alloc.dupeSentinel(u8, test_db.database.getPath() orelse return error.TestUnexpectedResult, 0);
    defer alloc.free(path);
    try test_db.database.close();

    const ro = switch (open(.read_only, .{
        .database_path = path,
        .config_path = "",
    })) {
        .ok => |db| db,
        .err => |e| {
            defer e.deinit();
            return e.err;
        },
    };
    defer ro.deinit() catch {};

    const query = try ro.queryCreate("*");
    defer query.deinit();
    try std.testing.expectEqual(@as(u32, fixture.corpus.len), try query.countMessages());
}

pub const CreateError = error{
    /// A database already exists at `database_path`, so it was not
    /// (re-)created.
    DatabaseExists,
    /// An error occurred trying to create the database or open the
    /// configuration file (such as permission denied, or file not found).
    FileError,
    /// No configuration file was found. Pass `""` as `config_path` to create
    /// the database without one.
    NoConfig,
    /// libnotmuch is older than 5.6, the minimum version these bindings
    /// support. Reported by the bindings themselves, before calling into
    /// libnotmuch.
    NotmuchVersion,
    /// Out of memory.
    OutOfMemory,
    /// A Xapian exception occurred.
    XapianException,
    /// libnotmuch returned an undocumented status code.
    Unexpected,
};

/// The result of `create`: either the newly created database or an error
/// paired with libnotmuch's human-readable message.
///
/// A tagged union is used instead of an error union because the message
/// accompanying a failure has to be retrieved and freed alongside the error;
/// call the `err` variant's `deinit` when done with it.
pub const CreateResult = union(enum) {
    /// The newly created database, open in read-write mode. The caller owns
    /// it and should call `Database.deinit` when finished with it.
    ok: Database,
    /// The failure, along with an optional message from libnotmuch.
    err: struct {
        /// The error corresponding to the status code libnotmuch returned.
        err: CreateError,
        /// The raw error message, if any. Use `message` to read it and
        /// `deinit` to free it.
        msg: [*c]u8,

        /// Return the human-readable error message from libnotmuch, or
        /// `null` if there is none. The string is owned by this result and
        /// is freed by `deinit`.
        pub fn message(self: @This()) ?[:0]const u8 {
            return std.mem.span(self.msg orelse return null);
        }

        /// Free the error message. Safe to call when there is no message.
        pub fn deinit(self: @This()) void {
            c.free(@ptrCast(@constCast(self.msg)));
        }
    },
};

/// Create a new notmuch database.
///
/// On success the caller owns the returned database (open in read-write mode)
/// and should call `deinit` when finished with it. On failure the `err`
/// variant carries the error and an optional human-readable message; the
/// caller should call its `deinit` to free the message.
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
        else => error.Unexpected,
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
        .ok => |db| db.deinit() catch {},
        .err => |e| e.deinit(),
    };
    try std.testing.expect(r == .ok);
}

pub const LoadConfigError = error{
    /// libnotmuch is older than 5.6, the minimum version these bindings
    /// support. Reported by the bindings themselves, before calling into
    /// libnotmuch.
    NotmuchVersion,
    /// Out of memory.
    OutOfMemory,
    /// An error occurred trying to open the database or configuration file
    /// (such as permission denied, or file not found).
    FileError,
    /// A Xapian exception occurred.
    XapianException,
    /// libnotmuch returned an undocumented status code.
    Unexpected,
};

/// A non-fatal condition reported by `loadConfig`.
pub const LoadConfigWarning = enum {
    /// No configuration file was loaded; defaults and any configuration
    /// stored in the database apply.
    no_config,
    /// No configuration was loaded from a database.
    no_database,
};

/// The result of `loadConfig`: either a configuration-only database object
/// (possibly with a non-fatal warning) or an error paired with libnotmuch's
/// human-readable message.
pub const LoadConfigResult = union(enum) {
    ok: struct {
        /// A database object suitable for configuration access (`configGet`
        /// and friends); the underlying Xapian database is not opened. The
        /// caller owns it and should call `Database.deinit` when finished.
        database: Database,
        /// A non-fatal condition encountered while loading, or `null` if
        /// configuration was loaded from both the config file and the
        /// database.
        warning: ?LoadConfigWarning,
    },
    /// The failure, along with an optional message from libnotmuch; call
    /// `deinit` to free the message.
    err: struct {
        /// The error corresponding to the status code libnotmuch returned.
        err: LoadConfigError,
        /// The raw error message, if any. Use `message` to read it and
        /// `deinit` to free it.
        msg: [*c]u8,

        /// Return the human-readable error message from libnotmuch, or
        /// `null` if there is none. The string is owned by this result and
        /// is freed by `deinit`.
        pub fn message(self: @This()) ?[:0]const u8 {
            return std.mem.span(self.msg orelse return null);
        }

        /// Free the error message. Safe to call when there is no message.
        pub fn deinit(self: @This()) void {
            c.free(@ptrCast(@constCast(self.msg)));
        }
    },
};

/// Load configuration from the config file, database, and/or defaults,
/// without opening the underlying Xapian database.
///
/// This is a lighter-weight alternative to `open` when only configuration
/// access is needed: the returned database object supports `configGet` and
/// the other configuration functions, but not searching or indexing. Missing
/// configuration sources are reported as non-fatal warnings rather than
/// errors.
pub fn loadConfig(options: OpenCreateOptions) LoadConfigResult {
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

    const rc = status(c.notmuch_database_load_config(
        options.database_path orelse null,
        options.config_path orelse null,
        options.profile orelse null,
        &database,
        &message,
    ));
    const err: LoadConfigError = switch (rc) {
        .success, .no_config, .no_database => {
            if (database) |db| {
                if (message != null) c.free(@ptrCast(message));
                return .{
                    .ok = .{
                        .database = .{ .database = db },
                        .warning = switch (rc) {
                            .success => null,
                            .no_config => .no_config,
                            .no_database => .no_database,
                            else => unreachable,
                        },
                    },
                };
            }
            return .{ .err = .{ .err = error.Unexpected, .msg = message } };
        },
        .out_of_memory => error.OutOfMemory,
        .file_error => error.FileError,
        .xapian_exception => error.XapianException,
        else => error.Unexpected,
    };

    return .{
        .err = .{
            .err = err,
            .msg = message,
        },
    };
}

test loadConfig {
    const fixture = @import("testing.zig");
    const alloc = std.testing.allocator;

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    // Load configuration through the fixture's config file, without opening
    // the Xapian database.
    const config_path = try alloc.dupeSentinel(u8, test_db.database.configPath() orelse return error.TestUnexpectedResult, 0);
    defer alloc.free(config_path);

    const loaded = switch (loadConfig(.{ .config_path = config_path })) {
        .ok => |ok| ok,
        .err => |e| {
            defer e.deinit();
            return e.err;
        },
    };
    defer loaded.database.deinit() catch {};
    try std.testing.expectEqual(@as(?LoadConfigWarning, null), loaded.warning);
    try std.testing.expectEqualStrings(
        "zig@example.org",
        try loaded.database.configGet(.primary_email) orelse return error.TestUnexpectedResult,
    );

    // Missing configuration sources are non-fatal warnings.
    const missing = switch (loadConfig(.{ .config_path = "", .database_path = "/nonexistent/notmuch-zig" })) {
        .ok => |ok| ok,
        .err => |e| {
            defer e.deinit();
            return e.err;
        },
    };
    defer missing.database.deinit() catch {};
    try std.testing.expect(missing.warning != null);
}

pub const CloseError = error{
    /// A Xapian exception occurred. The database has still been closed, but
    /// there is no guarantee that any changes were flushed to disk.
    XapianException,
    /// libnotmuch returned an undocumented status code.
    Unexpected,
};

/// Commit changes and close the given notmuch database.
///
/// After `close` has been called, calls to other functions on
/// objects derived from this database may either behave as if the database had
/// not been closed (e.g., if the required data has been cached) or may fail
/// with `error.XapianException` or `error.Unexpected`. The only further
/// operation permitted on the database itself is `deinit`.
///
/// If `close` returns `error.XapianException`, the database has still been
/// closed, but there is no guarantee that any changes were flushed to disk.
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
        else => return error.Unexpected,
    }
}

/// Compact the notmuch database, backing up the original database to the given
/// path.
///
/// The database will be opened in read-write mode during the compaction
/// process, to ensure no writes are made.
///
/// If the optional callback function `status_cb` is non-`null`, it will be
/// called with diagnostic and informational messages. The argument `closure` is
/// passed verbatim to any callback invoked.
///
/// WARNING: In practice this function is hard to use safely. Compaction opens
/// its own read-write handle to the database, so calling it through an open
/// read-write handle fails with `error.XapianException` (a Xapian lock
/// conflict) and can leave this handle unusable — even `reopen` may abort.
/// A read-only or closed handle is rejected outright. Prefer the module-level
/// `notmuch.compact`, which works on paths without an open database.
pub fn compact(self: *const Database, backup_path: [:0]const u8, status_cb: ?StatusCallback, closure: ?*anyopaque) Error!void {
    try wrap(c.notmuch_database_compact_db(self.database, backup_path, status_cb, closure));
}

/// Deinit the notmuch database, closing it if necessary and freeing all
/// associated resources.
///
/// Return value as in `close` if the database was open; `deinit` itself has no
/// failure modes.
///
/// NOTE: In the `notmuch` C API, this is referred to as a `destroy` operation.
/// This has been renamed to `deinit` to align with Zig's nomenclature and to
/// avoid the inference that this API call would delete data from disk.
pub fn deinit(self: *const Database) Error!void {
    switch (status(c.notmuch_database_destroy(self.database))) {
        .success => {},
        .xapian_exception => return error.XapianException,
        else => return error.Unexpected,
    }
}

/// Return the database path of the database.
///
/// The return value is a string owned by `notmuch` so should not be modified
/// nor freed by the caller; it remains valid until the database is
/// deinitialized.
pub fn getPath(self: *const Database) ?[:0]const u8 {
    return std.mem.span(c.notmuch_database_get_path(self.database) orelse return null);
}

test getPath {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // The path is the absolute location of the mail store the database was
    // opened on — here the fixture's "mail" directory.
    const path = db.getPath() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.fs.path.isAbsolute(path));
    try std.testing.expectEqualStrings("mail", std.fs.path.basename(path));
}

/// Retrieve the last status string for the database: the human-readable
/// diagnostic accompanying the most recent failure, if libnotmuch recorded
/// one. Returns `null` when there is none.
///
/// The returned string is owned by the database: it must not be modified or
/// freed by the caller, it may be invalidated by any later operation that
/// records a new diagnostic, and it is freed along with the database by
/// `deinit`. Copy it if it needs to outlive either.
pub fn statusString(self: *const Database) ?[:0]const u8 {
    return std.mem.span(c.notmuch_database_status_string(self.database) orelse return null);
}

test statusString {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // A healthy database has no status string.
    try std.testing.expectEqual(@as(?[:0]const u8, null), db.statusString());

    // After a failure, the diagnostic is retrievable.
    const bad = try db.queryCreateWithSyntax("(unbalanced", .sexp);
    defer bad.deinit();
    try std.testing.expectError(error.BadQuerySyntax, bad.countMessages());
    const diagnostic = db.statusString() orelse return error.TestUnexpectedResult;
    try std.testing.expect(diagnostic.len > 0);
}

/// Return the database format version of the database.
///
/// Returns `error.FormatVersionError` if the version cannot be determined
/// (for example, when the database has been closed).
pub fn getVersion(self: *const Database) error{FormatVersionError}!u32 {
    const version = c.notmuch_database_get_version(self.database);
    if (version == 0) return error.FormatVersionError;
    return version;
}

test getVersion {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const version = try test_db.database.getVersion();
    try std.testing.expect(version > 0);

    // A closed database has no determinable version.
    try test_db.database.close();
    try std.testing.expectError(error.FormatVersionError, test_db.database.getVersion());
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

/// Callback function that provides progress notification during a database
/// upgrade operation.
pub const ProgressCallback = *const fn (closure: ?*anyopaque, progress: f64) callconv(.c) void;

/// Upgrade the current database to the latest supported version.
///
/// This ensures that all current notmuch functionality will be available
/// on the database. After opening a database in read-write mode, it is
/// recommended that clients check if an upgrade is needed (`needsUpgrade`)
/// and if so, upgrade with this function before making any modifications. If
/// `needsUpgrade` returns `false`, this will be a no-op.
///
/// The optional `progress_cb` callback can be used by the caller to
/// provide progress indication to the user. If non-`null` it will be called
/// periodically with `progress` as a floating-point value in the range of [0.0
/// .. 1.0] indicating the progress made so far in the upgrade process. The
/// argument `closure` is passed verbatim to any callback invoked.
pub fn upgrade(self: *const Database, progress_cb: ?ProgressCallback, closure: ?*anyopaque) Error!void {
    try wrap(c.notmuch_database_upgrade(self.database, progress_cb, closure));
}

test upgrade {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // A freshly created database is already at the newest format version, so
    // upgrading is a harmless no-op.
    try std.testing.expect(!db.needsUpgrade());
    try db.upgrade(null, null);

    // A progress callback (with an optional closure) reports progress
    // during real upgrades.
    const callbacks = struct {
        fn progress(closure: ?*anyopaque, p: f64) callconv(.c) void {
            _ = closure;
            _ = p;
        }
    };
    try db.upgrade(callbacks.progress, null);
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
pub fn beginAtomic(self: *const Database) error{ XapianException, Unexpected }!void {
    switch (status(c.notmuch_database_begin_atomic(self.database))) {
        .success => {},
        .xapian_exception => return error.XapianException,
        else => return error.Unexpected,
    }
}

test beginAtomic {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    try db.beginAtomic();
    const message = try db.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try message.addTag("atomic-test");
    try db.endAtomic();

    var tags = message.getTags();
    try std.testing.expect(fixture.hasTag(&tags, "atomic-test"));
}

/// Indicate the end of an atomic database operation. If repeated (with matching
/// `beginAtomic`) "database.autocommit" times, commit the transaction and
/// all previous (non-cancelled) transactions to the database.
pub fn endAtomic(self: *const Database) error{ UnbalancedAtomic, XapianException, Unexpected }!void {
    switch (status(c.notmuch_database_end_atomic(self.database))) {
        .success => {},
        .unbalanced_atomic => return error.UnbalancedAtomic,
        .xapian_exception => return error.XapianException,
        else => return error.Unexpected,
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

test getRevision {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const message = try db.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();

    var previous = db.getRevision();
    for ([_][:0]const u8{ "mono-one", "mono-two", "mono-three" }) |tag| {
        try message.addTag(tag);
        const current = db.getRevision();
        try std.testing.expect(try current.compare(previous) == .gt);
        previous = current;
    }
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
/// such, will only be valid until the database is deinitialized with
/// `Database.deinit`.
pub fn getDirectory(self: *const Database, path: [:0]const u8) Error!?Directory {
    var directory: ?*c.notmuch_directory_t = null;

    return switch (status(c.notmuch_database_get_directory(self.database, path, &directory))) {
        .success => .{
            .directory = directory orelse return null,
        },
        .null_pointer => error.NullPointer,
        .upgrade_required => error.UpgradeRequired,
        .xapian_exception => error.XapianException,
        else => error.Unexpected,
    };
}

test getDirectory {
    const fixture = @import("testing.zig");

    const alloc = std.testing.allocator;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const root = db.getPath() orelse return error.TestUnexpectedResult;
    const new_path = try std.fs.path.joinZ(alloc, &.{ root, "new" });
    defer alloc.free(new_path);

    const directory = try db.getDirectory(new_path) orelse return error.TestUnexpectedResult;
    defer directory.deinit();

    try std.testing.expectEqual(@as(?i64, null), directory.getMtime());
    try directory.setMtime(12345);
    try std.testing.expectEqual(@as(?i64, 12345), directory.getMtime());

    var files = try directory.getChildFiles();
    defer files.deinit();
    var count: usize = 0;
    while (files.next()) |_| count += 1;
    try std.testing.expectEqual(fixture.corpus.len, count);

    var dirs = try directory.getChildDirectories();
    defer dirs.deinit();
    try std.testing.expectEqual(@as(?[:0]const u8, null), dirs.next());
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
    /// A Xapian exception occurred, message not added.
    XapianException,
    /// libnotmuch returned an undocumented status code.
    Unexpected,
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
/// expected to remain at its current location (since the notmuch database will
/// reference the filename, and will not copy the entire contents of the file).
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
/// Note that this does not synchronise Maildir flags to notmuch tags,
/// regardless of the value of `maildir.synchronize_flags`. If flags ought to
/// be synchronised, explicitly call `Message.maildirFlagsToTags`.
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
        .xapian_exception => error.XapianException,
        else => error.Unexpected,
    };
}

test indexFile {
    const fixture = @import("testing.zig");
    const alloc = std.testing.allocator;

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // Delivered into the mail store, but not yet known to the database.
    const delivered = try test_db.deliver(
        \\From: Erin <erin@example.org>
        \\To: Alice <alice@example.org>
        \\Subject: Indexed by hand
        \\Date: Thu, 04 Apr 2024 10:00:00 +0000
        \\Message-ID: <five@example.org>
        \\
        \\Indexed with Database.indexFile.
        \\
    , .{});

    const path = try test_db.pathOf(&delivered);
    defer alloc.free(path);

    try db.indexFile(path, null);
    const message = try db.findMessage("five@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try std.testing.expectEqualStrings("Indexed by hand", message.getHeader("Subject") orelse "");

    // Indexing a file whose message ID is already known merges silently;
    // duplicates are not an error.
    try db.indexFile(path, null);

    // A file in the mail store that is not an email is rejected.
    const junk = try test_db.deliver("", .{});
    const junk_path = try test_db.pathOf(&junk);
    defer alloc.free(junk_path);
    try std.testing.expectError(error.FileNotEmail, db.indexFile(junk_path, null));

    // A path outside the database's mail root is rejected before it is read.
    try std.testing.expectError(error.FileError, db.indexFile("/etc/hostname", null));
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
/// expected to remain at its current location (since the notmuch database will
/// reference the filename, and will not copy the entire contents of the file).
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
/// `Message.deinit` when done with the message.
///
/// Note that this does not synchronise Maildir flags to notmuch tags,
/// regardless of the value of `maildir.synchronize_flags`. If flags ought to
/// be synchronised, explicitly call `Message.maildirFlagsToTags`.
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
        .xapian_exception => error.XapianException,
        else => error.Unexpected,
    };
}

test indexFileGetMessage {
    const fixture = @import("testing.zig");

    const alloc = std.testing.allocator;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const delivered = try test_db.deliver(
        \\From: Erin <erin@example.org>
        \\To: Alice <alice@example.org>
        \\Subject: One more thing
        \\Date: Thu, 04 Apr 2024 10:00:00 +0000
        \\Message-ID: <five@example.org>
        \\
        \\Just one more thing.
        \\
    , .{});

    const path = try test_db.pathOf(&delivered);
    defer alloc.free(path);

    const message = try test_db.database.indexFileGetMessage(path, null);
    defer message.deinit();
    try std.testing.expectEqualStrings("five@example.org", message.getMessageID() orelse "");

    try test_db.database.reopen(.read_only);
    const query = try test_db.database.queryCreate("*");
    defer query.deinit();
    try std.testing.expectEqual(@as(u32, fixture.corpus.len + 1), try query.countMessages());
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
    /// libnotmuch returned an undocumented status code.
    Unexpected,
};

/// Remove a message filename from the given notmuch database. If the message
/// has no more filenames, remove the message.
///
/// If the same message (as determined by the message ID) is still available
/// via other filenames, then the message will persist in the database for those
/// filenames, and removing one of them reports `error.DuplicateMessageID`.
/// When the last filename is removed for a particular message, the database
/// content for that message will be entirely removed.
///
/// However, if the message ID is referenced by another message still in the
/// database (for example via In-Reply-To or References headers), removing the
/// last filename leaves behind a "ghost message": `findMessage` still finds
/// it, but it has only a message ID and thread ID, and `Message.getFlag` with
/// `.ghost` reports true for it.
pub fn removeMessage(self: *const Database, filename: [:0]const u8) RemoveMessageError!void {
    return switch (status(c.notmuch_database_remove_message(self.database, filename))) {
        .success => {},
        .duplicate_message_id => error.DuplicateMessageID,
        .read_only_database => error.ReadOnlyDatabase,
        .upgrade_required => error.UpgradeRequired,
        .xapian_exception => error.XapianException,
        else => error.Unexpected,
    };
}

test removeMessage {
    const fixture = @import("testing.zig");

    const alloc = std.testing.allocator;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // Deliver and index a second copy of the first corpus message: same
    // Message-ID, a name of its own, since a maildir never reuses one.
    const duplicate = try test_db.deliver(fixture.corpus[0].data, .{});

    const original = try test_db.path(0);
    defer alloc.free(original);
    const copy = try test_db.pathOf(&duplicate);
    defer alloc.free(copy);

    try db.indexFile(copy, null);

    const message = try db.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try std.testing.expectEqual(@as(usize, 2), try message.countFiles());

    // Removing one filename reports DuplicateMessageID: the filename is gone
    // but the message persists under the remaining filename.
    try std.testing.expectError(error.DuplicateMessageID, db.removeMessage(original));
    const remaining = try db.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer remaining.deinit();
    try std.testing.expectEqual(@as(usize, 1), try remaining.countFiles());
    try std.testing.expect(std.mem.endsWith(u8, try remaining.getFilename(), duplicate.filename()));

    // Removing the last filename removes the message content. Because
    // two@example.org references this message ID, notmuch keeps it as a
    // "ghost": findable, but with no files.
    try db.removeMessage(copy);
    const ghost = try db.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer ghost.deinit();
    try std.testing.expect(try ghost.getFlag(.ghost));
}

pub const FindMessageError = error{
    /// Out of memory creating message object.
    OutOfMemory,
    /// The database is in an older on-disk format that cannot look messages
    /// up by filename; call `Database.upgrade` first. Returned by
    /// `findMessageByFilename` only.
    UpgradeRequired,
    /// The underlying Xapian database reported an error — for example, the
    /// database has been closed, or an I/O failure occurred while reading
    /// it.
    XapianException,
    /// libnotmuch returned an undocumented status code.
    Unexpected,
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
        else => error.Unexpected,
    };
}

test findMessage {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // Look a message up by its Message-ID (without the angle brackets).
    const message = try db.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try std.testing.expectEqualStrings("Lunch plans", message.getHeader("Subject") orelse "");

    // An unknown message ID returns null.
    try std.testing.expectEqual(@as(?Message, null), try db.findMessage("missing@example.org"));
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
        .upgrade_required => error.UpgradeRequired,
        .xapian_exception => error.XapianException,
        else => error.Unexpected,
    };
}

test findMessageByFilename {
    const fixture = @import("testing.zig");

    const alloc = std.testing.allocator;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // Lookup by absolute filename.
    const abs = try test_db.path(1);
    defer alloc.free(abs);
    const by_abs = try db.findMessageByFilename(abs) orelse return error.TestUnexpectedResult;
    defer by_abs.deinit();
    try std.testing.expectEqualStrings("two@example.org", by_abs.getMessageID() orelse "");

    // Lookup by filename relative to the database path.
    const rel = try std.fs.path.joinZ(alloc, &.{ "new", test_db.filename(1) });
    defer alloc.free(rel);
    const by_rel = try db.findMessageByFilename(rel) orelse return error.TestUnexpectedResult;
    defer by_rel.deinit();
    try std.testing.expectEqualStrings("two@example.org", by_rel.getMessageID() orelse "");

    // Unknown filenames return null.
    try std.testing.expectEqual(@as(?Message, null), try db.findMessageByFilename("new/missing"));

    // A closed database reports a Xapian exception.
    try db.close();
    try std.testing.expectError(error.XapianException, db.findMessageByFilename(abs));
}

/// Return a list of all tags found in the database.
///
/// This function creates a list of all tags found in the database. The
/// resulting list contains all tags from all messages found in the database.
///
/// The caller owns the returned iterator and should release it with its
/// `deinit`; the tag strings it yields belong to the iterator.
///
/// On error this function returns `null`.
pub fn getAllTags(self: *const Database) ?TagsIterator {
    return .{
        .tags = c.notmuch_database_get_all_tags(self.database) orelse return null,
    };
}

test getAllTags {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const message = try db.findMessage("four@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try message.addTag("zig");

    var tags = db.getAllTags() orelse return error.TestUnexpectedResult;
    try std.testing.expect(fixture.hasTag(&tags, "zig"));
}

pub const ReopenError = error{
    /// The database was not open.
    IllegalArgument,
    /// A Xapian exception occurred.
    XapianException,
    /// libnotmuch returned an undocumented status code.
    Unexpected,
};

/// Reopen an open notmuch database.
///
/// Reopening switches the database to `mode` and picks up changes committed
/// by other connections since it was opened. It also brings a database
/// closed with `close` back into a usable state.
pub fn reopen(self: *Database, mode: Mode) ReopenError!void {
    return switch (status(c.notmuch_database_reopen(self.database, @backingInt(mode)))) {
        .success => {},
        .illegal_argument => error.IllegalArgument,
        .xapian_exception => error.XapianException,
        else => error.Unexpected,
    };
}

test reopen {
    const fixture = @import("testing.zig");

    const alloc = std.testing.allocator;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();

    const path = try alloc.dupeSentinel(u8, test_db.database.getPath() orelse return error.TestUnexpectedResult, 0);
    defer alloc.free(path);

    // A second, read-only connection to the same database.
    var reader = switch (open(.read_only, .{
        .database_path = path,
        .config_path = "",
    })) {
        .ok => |db| db,
        .err => |e| {
            defer e.deinit();
            return e.err;
        },
    };
    defer reader.deinit() catch {};

    {
        const query = try reader.queryCreate("tag:fresh");
        defer query.deinit();
        try std.testing.expectEqual(@as(u32, 0), try query.countMessages());
    }

    // The writer tags a message and commits by closing.
    const message = try test_db.database.findMessage("one@example.org") orelse return error.TestUnexpectedResult;
    defer message.deinit();
    try message.addTag("fresh");
    try test_db.database.close();

    // The reader sees the change only after reopening.
    try reader.reopen(.read_only);
    const query = try reader.queryCreate("tag:fresh");
    defer query.deinit();
    try std.testing.expectEqual(@as(u32, 1), try query.countMessages());
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
///
/// The caller should call `Query.deinit` when finished with the query.
pub fn queryCreate(self: *const Database, query_string: [:0]const u8) error{OutOfMemory}!Query {
    return .init(c.notmuch_query_create(self.database, query_string) orelse return error.OutOfMemory);
}

test queryCreate {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // A term query.
    const lunch = try db.queryCreate("subject:lunch");
    defer lunch.deinit();
    try std.testing.expectEqual(@as(u32, 2), try lunch.countMessages());

    // Both "" and "*" match all messages in the database.
    const empty = try db.queryCreate("");
    defer empty.deinit();
    try std.testing.expectEqual(@as(u32, fixture.corpus.len), try empty.countMessages());

    const star = try db.queryCreate("*");
    defer star.deinit();
    try std.testing.expectEqual(@as(u32, fixture.corpus.len), try star.countMessages());

    // Iterate the matches with searchMessages.
    var messages = try lunch.searchMessages();
    defer messages.deinit();
    var count: usize = 0;
    while (try messages.next()) |message| : (count += 1) message.deinit();
    try std.testing.expectEqual(@as(usize, 2), count);
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

    try wrap(c.notmuch_query_create_with_syntax(self.database, query_string, @backingInt(syntax), &query));

    return .init(query orelse return error.OutOfMemory);
}

test queryCreateWithSyntax {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // The s-expression syntax: () matches all messages.
    const all = try db.queryCreateWithSyntax("()", .sexp);
    defer all.deinit();
    try std.testing.expectEqual(@as(u32, fixture.corpus.len), try all.countMessages());

    // A field query in s-expression form.
    const lunch = try db.queryCreateWithSyntax("(subject lunch)", .sexp);
    defer lunch.deinit();
    try std.testing.expectEqual(@as(u32, 2), try lunch.countMessages());

    // The default Xapian syntax is available by name as well.
    const xapian = try db.queryCreateWithSyntax("subject:lunch", .xapian);
    defer xapian.deinit();
    try std.testing.expectEqual(@as(u32, 2), try xapian.countMessages());
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
    return std.mem.span(c.notmuch_config_get(self.database, @backingInt(key)) orelse return null);
}

test configGet {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // A value read from the configuration file the database was opened with.
    try std.testing.expectEqualStrings(
        "zig@example.org",
        try db.configGet(.primary_email) orelse return error.TestUnexpectedResult,
    );

    // A key with neither a configured value nor a default reads as null.
    try std.testing.expectEqual(@as(?[:0]const u8, null), try db.configGet(.other_email));
}

/// Set config `key` to `value`.
///
/// The database must be open in read-write mode.
pub fn configSet(self: *const Database, key: Config, value: [:0]const u8) Error!void {
    try wrap(c.notmuch_config_set(self.database, @backingInt(key), value));
}

test configSet {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // A value from the configuration file.
    try std.testing.expectEqualStrings(
        "zig@example.org",
        try db.configGet(.primary_email) orelse return error.TestUnexpectedResult,
    );

    // Round-trip through the database, including overwriting.
    try db.configSet(.user_name, "Test User");
    try std.testing.expectEqualStrings(
        "Test User",
        try db.configGet(.user_name) orelse return error.TestUnexpectedResult,
    );
    try db.configSet(.user_name, "Renamed User");
    try std.testing.expectEqualStrings(
        "Renamed User",
        try db.configGet(.user_name) orelse return error.TestUnexpectedResult,
    );

    // Values set through configSet persist across close and reopen.
    try db.close();
    try test_db.database.reopen(.read_write);
    try std.testing.expectEqualStrings(
        "Renamed User",
        try db.configGet(.user_name) orelse return error.TestUnexpectedResult,
    );

    // configSet requires a read-write database.
    try test_db.database.reopen(.read_only);
    try std.testing.expectError(error.ReadOnlyDatabase, db.configSet(.user_name, "nope"));
}

/// A configuration value returned by `configGetString`. The caller owns it
/// and must call `deinit` to free it.
pub const ConfigString = struct {
    /// The configuration value; `""` for a key that has never been set.
    value: [:0]const u8,

    /// Free the value.
    pub fn deinit(self: ConfigString) void {
        c.free(@ptrCast(@constCast(self.value.ptr)));
    }
};

/// Retrieve the configuration item `key` from an open database.
///
/// Unlike `configGet`, which is limited to the keys notmuch knows about, any
/// string key can be read — including ones private to an application (for
/// example "zig.custom"). A key which has never been set reads as the empty
/// string.
///
/// The caller owns the returned value and must call its `deinit` to free it.
pub fn configGetString(self: *const Database, key: [:0]const u8) Error!ConfigString {
    var value: [*c]u8 = null;
    try wrap(c.notmuch_database_get_config(self.database, key, &value));
    if (value == null) return error.Unexpected;
    return .{ .value = std.mem.span(value) };
}

/// Set the configuration item `key` to `value`.
///
/// Unlike `configSet`, which is limited to the keys notmuch knows about, any
/// string key can be written. The value is stored in the database itself,
/// not in the configuration file. The database must be open in read-write
/// mode.
pub fn configSetString(self: *const Database, key: [:0]const u8, value: [:0]const u8) Error!void {
    try wrap(c.notmuch_database_set_config(self.database, key, value));
}

test configSetString {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // Any key can be stored and read back, including application-private
    // ones.
    try db.configSetString("zig.custom", "hello");
    const custom = try db.configGetString("zig.custom");
    defer custom.deinit();
    try std.testing.expectEqualStrings("hello", custom.value);

    // A key that has never been set reads as the empty string.
    const unset = try db.configGetString("zig.never-set");
    defer unset.deinit();
    try std.testing.expectEqualStrings("", unset.value);

    // Writing requires a read-write database.
    try test_db.database.reopen(.read_only);
    try std.testing.expectError(error.ReadOnlyDatabase, db.configSetString("zig.custom", "nope"));
}

/// Returns an iterator for a `;`-delimited list of configuration values.
///
/// These values reflect all configuration information given at the
/// time the database was opened.
///
/// Returns `null` in case of error.
pub fn configGetValues(
    self: *const Database,
    /// configuration key
    key: Config,
) ?ValuesIterator {
    return .{
        .values = c.notmuch_config_get_values(self.database, @backingInt(key)) orelse return null,
    };
}

test configGetValues {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    try db.configSet(.exclude_tags, "spam;deleted");

    var values = db.configGetValues(.exclude_tags) orelse return error.TestUnexpectedResult;
    defer values.deinit();
    try std.testing.expectEqualStrings("spam", values.next() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("deleted", values.next() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(?[:0]const u8, null), values.next());

    // start() resets the iterator to the first value.
    values.start();
    try std.testing.expectEqualStrings("spam", values.next() orelse return error.TestUnexpectedResult);
}

/// Returns an iterator for a ';'-delimited list of configuration values
///
/// These values reflect all configuration information given at the
/// time the database was opened.
///
/// Returns `null` in case of error.
pub fn configGetValuesString(
    self: *const Database,
    /// configuration key
    key: [:0]const u8,
) ?ValuesIterator {
    return .{
        .values = c.notmuch_config_get_values_string(self.database, key) orelse return null,
    };
}

test configGetValuesString {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // Default configuration is visible through string keys: new.tags
    // defaults to unread;inbox.
    var new_tags = db.configGetValuesString("new.tags") orelse return error.TestUnexpectedResult;
    defer new_tags.deinit();
    var saw_unread = false;
    var saw_inbox = false;
    while (new_tags.next()) |value| {
        if (std.mem.eql(u8, value, "unread")) saw_unread = true;
        if (std.mem.eql(u8, value, "inbox")) saw_inbox = true;
    }
    try std.testing.expect(saw_unread);
    try std.testing.expect(saw_inbox);

    // A string key reads the same configuration as its typed equivalent.
    try db.configSet(.exclude_tags, "spam;deleted");
    var excluded = db.configGetValuesString("search.exclude_tags") orelse return error.TestUnexpectedResult;
    defer excluded.deinit();
    try std.testing.expectEqualStrings("spam", excluded.next() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("deleted", excluded.next() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(?[:0]const u8, null), excluded.next());

    // An unknown key yields no iterator at all.
    try std.testing.expect(db.configGetValuesString("bogus.key") == null);
}

/// Returns an iterator for (key, value) configuration pairs whose keys start
/// with `prefix`. Pass "" as the prefix to iterate over all pairs.
///
/// Returns `null` in case of error.
pub fn configGetPairs(self: *const Database, prefix: [:0]const u8) ?PairsIterator {
    return .{
        .pairs = c.notmuch_config_get_pairs(self.database, prefix) orelse return null,
    };
}

test configGetPairs {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    try db.configSet(.user_name, "Test User");

    // A prefix restricts iteration to matching keys.
    var user_pairs = db.configGetPairs("user.") orelse return error.TestUnexpectedResult;
    defer user_pairs.deinit();
    var user_count: usize = 0;
    var saw_name = false;
    while (user_pairs.next()) |pair| {
        try std.testing.expect(std.mem.startsWith(u8, pair.key, "user."));
        if (std.mem.eql(u8, pair.key, "user.name")) {
            saw_name = true;
            try std.testing.expectEqualStrings("Test User", pair.value orelse "");
        }
        user_count += 1;
    }
    try std.testing.expect(saw_name);

    // The empty prefix iterates over all pairs, a superset of any prefix.
    var all_pairs = db.configGetPairs("") orelse return error.TestUnexpectedResult;
    defer all_pairs.deinit();
    var all_count: usize = 0;
    var saw_null_value = false;
    while (all_pairs.next()) |pair| {
        if (pair.value == null) saw_null_value = true;
        all_count += 1;
    }
    try std.testing.expect(all_count > user_count);

    // Some keys carry no value; next() reports them as null rather than
    // crashing (regression check for the PairsIterator NULL-value fix).
    try std.testing.expect(saw_null_value);

    // An unknown prefix yields an empty iteration.
    var unknown = db.configGetPairs("bogus.") orelse return error.TestUnexpectedResult;
    defer unknown.deinit();
    try std.testing.expect(unknown.next() == null);
}

/// Get a configuration value from an open database as boolean.
///
/// This value reflects all configuration information given at the time the
/// database was opened.
///
/// Returns IllegalArgument error if either key is unknown or the
/// corresponding value does not convert to boolean.
pub fn configGetBool(
    /// The database
    self: *const Database,
    /// configuration key
    key: Config,
) Error!bool {
    var value: c.notmuch_bool_t = undefined;
    try wrap(c.notmuch_config_get_bool(self.database, @backingInt(key), &value));
    return value != 0;
}

test configGetBool {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // maildir.synchronize_flags defaults to true.
    try std.testing.expect(try db.configGetBool(.sync_maildir_flags));

    // Boolean values round-trip through configSet.
    try db.configSet(.sync_maildir_flags, "false");
    try std.testing.expect(!try db.configGetBool(.sync_maildir_flags));
    try db.configSet(.sync_maildir_flags, "true");
    try std.testing.expect(try db.configGetBool(.sync_maildir_flags));

    // A value that does not convert to a boolean is rejected.
    try std.testing.expectError(error.IllegalArgument, db.configGetBool(.primary_email));
}

/// Return the path of the config file loaded. Returns `null` if no config file
/// was loaded. A database opened with `""` as `config_path` (explicitly no
/// configuration file) reports `""` rather than `null`.
///
/// The returned string is owned by the database: it must not be modified or
/// freed by the caller, and it remains valid until the database is
/// deinitialized.
pub fn configPath(self: *const Database) ?[:0]const u8 {
    return std.mem.span(c.notmuch_config_path(self.database) orelse return null);
}

test configPath {
    const fixture = @import("testing.zig");

    const alloc = std.testing.allocator;
    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // The reported path is the config file the database was opened with,
    // which the fixture places next to the mail root.
    const root = db.getPath() orelse return error.TestUnexpectedResult;
    const expected = try std.fs.path.join(alloc, &.{
        std.fs.path.dirname(root) orelse return error.TestUnexpectedResult,
        "config",
    });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, db.configPath() orelse return error.TestUnexpectedResult);

    // A database opened with config_path "" reports the empty string as its
    // config path rather than null.
    const path = try alloc.dupeSentinel(u8, root, 0);
    defer alloc.free(path);
    try db.close();
    const no_config = switch (open(.read_only, .{
        .database_path = path,
        .config_path = "",
    })) {
        .ok => |d| d,
        .err => |e| {
            defer e.deinit();
            return e.err;
        },
    };
    defer no_config.deinit() catch {};
    try std.testing.expectEqualStrings("", no_config.configPath() orelse return error.TestUnexpectedResult);
}

/// Get the current default indexing options for a given database.
///
/// This object will survive until the database itself is destroyed, but the
/// caller may also release it earlier with `IndexOpts.deinit`.
///
/// This object represents a set of options on how a message can be added to the
/// index. At the moment it is a featureless stub.
pub fn getDefaultIndexOpts(self: *const Database) ?IndexOpts {
    return .{
        .indexopts = c.notmuch_database_get_default_indexopts(self.database) orelse return null,
    };
}

test getDefaultIndexOpts {
    const fixture = @import("testing.zig");

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    // With no index.decrypt configuration, the default policy is auto.
    const indexopts = db.getDefaultIndexOpts() orelse return error.TestUnexpectedResult;
    defer indexopts.deinit();
    try std.testing.expectEqual(IndexOpts.Decrypt.auto, indexopts.getDecryptPolicy());

    // Every policy value round-trips.
    for ([_]IndexOpts.Decrypt{ .false, .true, .auto, .nostash }) |policy| {
        try indexopts.setDecryptPolicy(policy);
        try std.testing.expectEqual(policy, indexopts.getDecryptPolicy());
    }

    // Changing one options object does not change the database default.
    const fresh = db.getDefaultIndexOpts() orelse return error.TestUnexpectedResult;
    defer fresh.deinit();
    try std.testing.expectEqual(IndexOpts.Decrypt.auto, fresh.getDecryptPolicy());
}

test {
    std.testing.refAllDecls(@This());
}
