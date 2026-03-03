// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Zig wrapper around the `notmuch` directory APIs.
const Directory = @This();

const std = @import("std");
const c = @import("c");

const Error = @import("error.zig").Error;
const FilenamesIterator = @import("FilenamesIterator.zig");
const wrap = @import("error.zig").wrap;

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
///   o Call `Directory.indexFile` for all mail files in the directory
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

/// Get the mtime of a directory, (as previously stored with `setMtime`).
///
/// Returns `null` if no mtime has previously been stored for this directory.
pub fn getMtime(self: *const Directory) Error!?i64 {
    const mtime = try wrap(c.notmuch_directory_get_mtime(self.directory));
    if (mtime == 0) return null;
    return @intCast(mtime);
}

pub const GetChildFilesError = error{
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

pub const GetChildDirectoriesError = error{
    XapianException,
};

/// Get a `FilenamesIterator` listing all the filenames of sub-directories in
/// the database within the given directory.
///
/// The returned filenames will be the basename-entries only (not complete
/// paths).
pub fn getChildDirectories(self: *const Directory) GetChildDirectoriesError!FilenamesIterator {
    return .{
        .filenames = c.notmuch_directory_get_child_files(self.directory) orelse return error.XapianException,
    };
}

/// Delete directory document from the database, and deinitialize the
/// `Directory` object. Assumes any child directories and files have been
/// deleted by the caller.
pub fn delete(self: *const Directory) Error!void {
    try wrap(c.notmuch_directory_delete(self.directory));
}

/// Deinitialize a `Directory` object.
pub fn deinit(self: *const Directory) void {
    c.notmuch_directory_destroy(self.directory);
}
