// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! A directory entry in the notmuch database, obtained from
//! `Database.getDirectory`.
//!
//! Stores a directory modification time (`getMtime`/`setMtime`) so callers
//! can efficiently detect new mail, and lists the database's knowledge of the
//! directory's contents via `getChildFiles` and `getChildDirectories`. The
//! directory object is owned by the database; `deinit` releases it sooner.
const Directory = @This();

const std = @import("std");
const c = @import("c");

const Error = @import("error.zig").Error;
const FilenamesIterator = @import("FilenamesIterator.zig");
const wrap = @import("error.zig").wrap;

/// The underlying `notmuch_directory_t` handle; only needed directly when
/// calling libnotmuch C APIs these bindings do not wrap.
directory: *c.notmuch_directory_t,

/// Store an mtime within the database for `Directory`.
///
/// The `Directory` should be an object retrieved from the database
/// with `Database.getDirectory` for a particular path.
///
/// The intention is for the caller to use the mtime to allow efficient
/// identification of new messages to be added to the database. The recommended
/// usage is as follows:
///
///   o Read the mtime of a directory from the filesystem
///
///   o Call `Database.indexFile` for all mail files in the directory
///
///   o Call `setMtime` with the mtime read from the
///     filesystem.
///
/// Then, when wanting to check for updates to the directory in the future, the
/// client can call `getMtime` and know that it only needs to add files if the
/// mtime of the directory and files are newer than the stored timestamp.
///
/// Note: The `getMtime` function does not allow the caller to distinguish a
/// timestamp of 0 from a non-existent timestamp. So don't store a timestamp of
/// 0 unless you are comfortable with that.
pub fn setMtime(self: *const Directory, mtime: i64) Error!void {
    try wrap(c.notmuch_directory_set_mtime(self.directory, mtime));
}

test setMtime {
    const fixture = @import("testing.zig");
    const alloc = std.testing.allocator;

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const root = db.getPath() orelse return error.TestUnexpectedResult;
    const cur_path = try std.fs.path.joinZ(alloc, &.{ root, "cur" });
    defer alloc.free(cur_path);

    const directory = try db.getDirectory(cur_path) orelse return error.TestUnexpectedResult;
    defer directory.deinit();

    // The stored mtime is read back with getMtime.
    try directory.setMtime(1711962000);
    try std.testing.expectEqual(@as(?i64, 1711962000), directory.getMtime());
}

/// Get the mtime of a directory, (as previously stored with `setMtime`).
///
/// Returns `null` if no mtime has previously been stored for this directory.
pub fn getMtime(self: *const Directory) ?i64 {
    const mtime = c.notmuch_directory_get_mtime(self.directory);
    if (mtime == 0) return null;
    return @intCast(mtime);
}

test getMtime {
    const fixture = @import("testing.zig");
    const alloc = std.testing.allocator;

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const root = db.getPath() orelse return error.TestUnexpectedResult;
    const cur_path = try std.fs.path.joinZ(alloc, &.{ root, "cur" });
    defer alloc.free(cur_path);

    const directory = try db.getDirectory(cur_path) orelse return error.TestUnexpectedResult;
    defer directory.deinit();

    // No mtime has been stored yet.
    try std.testing.expectEqual(@as(?i64, null), directory.getMtime());

    // The documented caveat: a stored timestamp of 0 cannot be
    // distinguished from a non-existent one.
    try directory.setMtime(0);
    try std.testing.expectEqual(@as(?i64, null), directory.getMtime());
}

pub const GetChildFilesError = error{
    /// A Xapian exception occurred.
    XapianException,
};

/// Get a `FilenamesIterator` listing all the filenames of messages in the
/// database within the given directory.
///
/// The returned filenames will be the basename-entries only (not complete
/// paths).
pub fn getChildFiles(self: *const Directory) GetChildFilesError!FilenamesIterator {
    return .{
        .filenames = c.notmuch_directory_get_child_files(self.directory) orelse return error.XapianException,
    };
}

test getChildFiles {
    const fixture = @import("testing.zig");
    const alloc = std.testing.allocator;

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const root = db.getPath() orelse return error.TestUnexpectedResult;
    const cur_path = try std.fs.path.joinZ(alloc, &.{ root, "cur" });
    defer alloc.free(cur_path);

    const directory = try db.getDirectory(cur_path) orelse return error.TestUnexpectedResult;
    defer directory.deinit();

    // All the indexed corpus messages live in cur; the entries are
    // basenames, not complete paths.
    var files = try directory.getChildFiles();
    defer files.deinit();
    var count: usize = 0;
    while (files.next()) |name| {
        try std.testing.expect(std.mem.indexOfScalar(u8, name, '/') == null);
        count += 1;
    }
    try std.testing.expectEqual(fixture.corpus.len, count);
}

pub const GetChildDirectoriesError = error{
    /// A Xapian exception occurred.
    XapianException,
};

/// Get a `FilenamesIterator` listing all the filenames of sub-directories in
/// the database within the given directory.
///
/// The returned filenames will be the basename-entries only (not complete
/// paths).
pub fn getChildDirectories(self: *const Directory) GetChildDirectoriesError!FilenamesIterator {
    return .{
        .filenames = c.notmuch_directory_get_child_directories(self.directory) orelse return error.XapianException,
    };
}

test getChildDirectories {
    const fixture = @import("testing.zig");
    const alloc = std.testing.allocator;

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const root = db.getPath() orelse return error.TestUnexpectedResult;

    // The mail root knows about cur, where the corpus was indexed.
    const mail_root = try db.getDirectory(root) orelse return error.TestUnexpectedResult;
    defer mail_root.deinit();
    var dirs = try mail_root.getChildDirectories();
    defer dirs.deinit();
    var saw_cur = false;
    while (dirs.next()) |name| {
        if (std.mem.eql(u8, name, "cur")) saw_cur = true;
    }
    try std.testing.expect(saw_cur);

    // cur itself has no sub-directories in the database.
    const cur_path = try std.fs.path.joinZ(alloc, &.{ root, "cur" });
    defer alloc.free(cur_path);
    const cur = try db.getDirectory(cur_path) orelse return error.TestUnexpectedResult;
    defer cur.deinit();
    var none = try cur.getChildDirectories();
    defer none.deinit();
    try std.testing.expectEqual(@as(?[:0]const u8, null), none.next());
}

/// Delete directory document from the database, and deinitialize the
/// `Directory` object. Assumes any child directories and files have been
/// deleted by the caller.
pub fn delete(self: *const Directory) Error!void {
    try wrap(c.notmuch_directory_delete(self.directory));
}

test delete {
    const fixture = @import("testing.zig");
    const alloc = std.testing.allocator;

    var test_db = try fixture.corpusDatabase();
    defer test_db.deinit();
    const db = test_db.database;

    const root = db.getPath() orelse return error.TestUnexpectedResult;
    const cur_path = try std.fs.path.joinZ(alloc, &.{ root, "cur" });
    defer alloc.free(cur_path);

    // Store an mtime, then delete the directory document. delete also
    // deinitializes the object, so no deinit call follows.
    const directory = try db.getDirectory(cur_path) orelse return error.TestUnexpectedResult;
    try directory.setMtime(1711962000);
    try directory.delete();

    // The directory document is gone from the database.
    try std.testing.expectEqual(@as(?Directory, null), try db.getDirectory(cur_path));
}

/// Deinitialize a `Directory` object.
pub fn deinit(self: *const Directory) void {
    c.notmuch_directory_destroy(self.directory);
}
