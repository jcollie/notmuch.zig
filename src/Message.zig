// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Zig wrapped around the `notmuch` C APIs that deal with messages.
const Message = @This();

const std = @import("std");

const c = @import("c");

const Database = @import("Database.zig");
const Error = @import("error.zig").Error;
const FilenamesIterator = @import("FilenamesIterator.zig");
const IndexOpts = @import("IndexOpts.zig");
const MaildirFlag = @import("enums.zig").MaildirFlag;
const MessageFlag = @import("enums.zig").MessageFlag;
const MessagesIterator = @import("MessagesIterator.zig");
const PropertiesIterator = @import("PropertiesIterator.zig");
const status = @import("enums.zig").status;
const TagsIterator = @import("TagsIterator.zig");
const wrap = @import("error.zig").wrap;

duplicate: ?bool = null,
message: *c.notmuch_message_t,

/// Get the database associated with this message.
pub fn getDatabase(self: *const Message) Database {
    return .{
        .database = c.notmuch_message_get_database(self.message) orelse unreachable,
    };
}

/// Get the message ID of `Message`.
///
/// The returned string belongs to `Message` and as such, should not be modified
/// or freed by the caller and will only be valid for as long as the message is
/// valid, which is until the query from which it derived is destroyed.
///
/// This function will return `null` if triggers an unhandled Xapian exception.
pub fn getMessageID(self: *const Message) ?[:0]const u8 {
    return std.mem.span(c.notmuch_message_get_message_id(self.message) orelse return null);
}

/// Get the thread ID of `Message`.
///
/// The returned string belongs to `Message` and as such, should not be modified
/// or freed by the caller and will only be valid for as long as the message is
/// valid, which is until the user calls `deinit` or until the query from which
/// it derived is deinitialized).
///
/// This function will return `null` if triggers an unhandled Xapian exception.
pub fn getThreadID(self: *const Message) ?[:0]const u8 {
    return std.mem.span(c.notmuch_message_get_thread_id(self.message) orelse return null);
}

/// Get a `MessagesIterator` for all of the replies to `Message`.
///
/// Note: This call only makes sense if `Message` was ultimately obtained from
/// a `Thread` object, (such as by coming directly from the result of calling
/// `Threads.getToplevelMessages` or by any number of subsequent calls to
/// `getReplies`).
///
/// If `Message` was obtained through some non-thread means, (such as by a
/// call to `Query.searchMessages`), then this function will return an empty
/// iterator.
///
/// If there are no replies to `Message`, this function will return an empty
/// iterator.
///
/// This function also return an empty iterator if it triggers a Xapian
/// exception.
///
/// The returned list will be deinitialized when the thread is denitialized.
pub fn getReplies(self: *const Message) MessagesIterator {
    return .{
        .messages = c.notmuch_message_get_replies(self.message),
    };
}

pub const CountFilesError = error{
    /// An error occurred while trying to count files.
    CountFilesError,
};

/// Get the total number of files associated with a message.
pub fn countFiles(self: *const Message) CountFilesError!usize {
    std.debug.assert(@typeInfo(c_int).int.bits <= @typeInfo(usize).int.bits);
    const count = c.notmuch_message_count_files(self.message);
    if (count < 0) return error.CountFilesError;
    return @intCast(@max(0, count));
}

pub const GetFilenameError = error{
    XapianException,
};

/// Get a filename for the email corresponding to `Message`.
///
/// The returned filename is an absolute filename (the initial component will
/// match `Database.getPath`).
///
/// The returned string belongs to the message so should not be modified or
/// freed by the caller (nor should it be referenced after the message is
/// deinitialized).
///
/// Note: If this message corresponds to multiple files in the mail store,
/// (that is, multiple files contain identical message IDs), this function will
/// arbitrarily return a single one of those filenames. See `getFilenames` for
/// returning the complete list of filenames.
///
/// This function returns NULL if it triggers a Xapian exception.
pub fn getFilename(self: *const Message) GetFilenameError![:0]const u8 {
    return std.mem.span(c.notmuch_message_get_filename(self.message) orelse return error.XapianException);
}

pub const GetFilenamesError = error{
    XapianException,
};

/// Get all filenames for the email corresponding to `Message`.
///
/// Returns a `FilenamesIterator` listing all the filenames associated with
/// `Message`. These files may not have identical content, but each will have
/// the identical Message-ID.
///
/// Each filename in the iterator is an absolute filename (the initial component
/// will match `Database.getPath`).
pub fn getFilenames(self: *const Message) GetFilenamesError!FilenamesIterator {
    return .{
        .filenames = c.notmuch_message_get_filenames(self.message) orelse return error.XapianException,
    };
}

pub fn reindex(self: *const Message, indexopts: ?IndexOpts) Error!void {
    return switch (status(c.notmuch_message_reindex(self.message, if (indexopts) |i| i.indexopts else null))) {
        .success => {},
        .duplicate_message_id => {},
        .file_error => error.FileError,
        .file_not_email => error.FileNotEmail,
        .read_only_database => error.ReadOnlyDatabase,
        .upgrade_required => error.UpgradeRequired,
        else => unreachable,
    };
}

pub const GetFlagError = error{
    XapianException,
};

/// Get a value of a flag for the email corresponding to `Message`.
pub fn getFlag(self: *const Message, flag: MessageFlag) GetFlagError!bool {
    var is_set: c.notmuch_bool_t = undefined;
    return switch (status(c.notmuch_message_get_flag_st(
        self.message,
        @intFromEnum(flag),
        &is_set,
    ))) {
        .success => is_set != 0,
        .null_pointer => unreachable,
        .xapian_exception => error.XapianException,
        else => unreachable,
    };
}

/// Set a value of a flag for the email corresponding to `Message`.
pub fn setFlag(self: *const Message, flag: MessageFlag, value: bool) void {
    c.notmuch_message_set_flag(self.message, @intFromEnum(flag), @intFromBool(value));
}

/// Get the date of `Message` as the number of seconds since the Unix epoch
/// (1970-01-01 00:00:00 UTC).
///
/// For the original textual representation of the `Date` header from the
/// message call `getHeader` with a header value of "date".
///
/// Returns `null` in case of error.
pub fn getDate(self: *const Message) ?i64 {
    std.debug.assert(@typeInfo(c.time_t).int.bits <= @typeInfo(i64).int.bits);
    const time = c.notmuch_message_get_date(self.message);
    if (time == 0) return null;
    return @intCast(time);
}

/// Get the value of the specified header from `Message` as a UTF-8 string.
///
/// Common headers are stored in the database when the message is indexed and
/// will be returned from the database. Other headers will be read from the
/// actual message file.
///
/// The header name is case insensitive.
///
/// The returned string belongs to the message so should not be modified or
/// freed by the caller (nor should it be referenced after the message is
/// deinitialized).
///
/// Returns an empty string ("") if the message does not contain a header line
/// matching 'header'. Returns `null` if any error occurs.
pub fn getHeader(self: *const Message, header: [:0]const u8) ?[:0]const u8 {
    return std.mem.span(c.notmuch_message_get_header(self.message, header) orelse return null);
}

/// Get the tags for `Message`, returning a `TagsIterator` object which can be
/// used to iterate over all tags.
///
/// The tags object is owned by the message and as such, will only be valid
/// for as long as the message is valid, which is until the query from which it
/// derived is deinitialized.
pub fn getTags(self: *const Message) TagsIterator {
    return .{
        .tags = c.notmuch_message_get_tags(self.message),
    };
}

pub const AddTagError = error{
    /// The length of `tag` is too long (exceeds NOTMUCH_TAG_MAX).
    TagTooLong,
    /// Database was opened in read-only mode so message cannot be modified.
    ReadOnlyDatabase,
};

/// Add a tag to the given message.
pub fn addTag(self: *const Message, tag: [:0]const u8) AddTagError!void {
    return switch (status(c.notmuch_message_add_tag(self.message, tag))) {
        .success => {},
        .null_pointer => unreachable,
        .tag_too_long => error.TagTooLong,
        .read_only_database => error.ReadOnlyDatabase,
        else => unreachable,
    };
}

pub const RemoveTagError = error{
    /// The length of `tag` is too long (exceeds NOTMUCH_TAG_MAX).
    TagTooLong,
    /// Database was opened in read-only mode so message cannot be modified.
    ReadOnlyDatabase,
};

/// Remove a tag from the given message.
pub fn removeTag(self: *const Message, tag: [:0]const u8) RemoveTagError!void {
    return switch (status(c.notmuch_message_add_tag(self.message, tag))) {
        .success => {},
        .null_pointer => unreachable,
        .tag_too_long => error.TagTooLong,
        .read_only_database => error.ReadOnlyDatabase,
        else => unreachable,
    };
}

pub const RemoveAllTagsError = error{
    /// Database was opened in read-only mode so message cannot be modified.
    ReadOnlyDatabase,
    XapianException,
};

/// Remove all tags from the given message.
///
/// See `freeze` for an example showing how to safely replace tag values.
pub fn removeAllTags(self: *const Message) RemoveAllTagsError!void {
    return switch (status(c.notmuch_message_remove_all_tags(self.message))) {
        .success => {},
        .read_only_database => error.ReadOnlyDatabase,
        .xapian_exception => error.XapianException,
        else => unreachable,
    };
}

/// Add/remove tags according to maildir flags in the message filename(s).
///
/// This function examines the filenames of `Message` for maildir flags, and
/// adds or removes tags on `Message` as follows when these flags are present:
///
///      Flag    Action if present
///      ----    -----------------
///      'D'     Adds the "draft" tag to the message
///      'F'     Adds the "flagged" tag to the message
///      'P'     Adds the "passed" tag to the message
///      'R'     Adds the "replied" tag to the message
///      'S'     Removes the "unread" tag from the message
///
/// For each flag that is not present, the opposite action (add/remove) is
/// performed for the corresponding tags.
///
/// Flags are identified as trailing components of the filename after a
/// sequence of ":2,".
///
/// If there are multiple filenames associated with this message, the flag
/// is considered present if it appears in one or more filenames. (That is,
/// the flags from the multiple filenames are combined with the logical OR
/// operator.)
///
/// A client can ensure that notmuch database tags remain synchronized
/// with maildir flags by calling this function after each call to
/// `Database.indexFile`. See also `tagsToMaildirFlags` for synchronizing tag
/// changes back to maildir flags.
pub fn maildirFlagsToTags(self: *const Message) Error!void {
    try wrap(c.notmuch_message_maildir_flags_to_tags(self.message));
}

pub const HasMaildirFlagError = error{
    XapianException,
};

/// Check message for maildir flag.
pub fn hasMaildirFlag(self: *const Message, flag: MaildirFlag) HasMaildirFlagError!bool {
    var is_set: c.notmuch_bool_t = undefined;
    return switch (status(c.notmuch_message_has_maildir_flag_st(self.message, @intFromEnum(flag), &is_set))) {
        .success => is_set != 0,
        .null_pointer => unreachable,
        .xapian_exception => error.XapianException,
        else => unreachable,
    };
}

/// Rename message filename(s) to encode tags as maildir flags.
///
/// Specifically, for each filename corresponding to this message:
///
/// If the filename is not in a maildir directory, do nothing.  (A maildir
/// directory is determined as a directory named "new" or "cur".) Similarly, if
/// the filename has invalid maildir info, (repeated or outof-ASCII-order flag
/// characters after ":2,"), then do nothing.
///
/// If the filename is in a maildir directory, rename the file so that its
/// filename ends with the sequence ":2," followed by zero or more of the
/// following single-character flags (in ASCII order):
///
///   * flag 'D' iff the message has the "draft" tag
///   * flag 'F' iff the message has the "flagged" tag
///   * flag 'P' iff the message has the "passed" tag
///   * flag 'R' iff the message has the "replied" tag
///   * flag 'S' iff the message does not have the "unread" tag
///
/// Any existing flags unmentioned in the list above will be preserved in the
/// renaming.
///
/// Also, if this filename is in a directory named "new", rename it to be within
/// the neighboring directory named "cur".
///
/// A client can ensure that maildir filename flags remain synchronized
/// with notmuch database tags by calling this function after changing tags
/// (after calls to `addTag`, `removeTag`, or `freeze`/`thaw`). See also
/// `maildirFlagsToTags` for synchronizing maildir flag changes back to tags.
pub fn tagsToMaildirFlags(self: *const Message) Error!void {
    try wrap(c.notmuch_message_tags_to_maildir_flags(self.message));
}

/// Freeze the current state of `Message` within the database.
///
/// This means that changes to the message state, (via `addTag`, `removeTag`,
/// and `removeAllTags`), will not be committed to the database until the
/// message is thawed with `thaw`.
///
/// Multiple calls to `freeze`/`thaw` are valid and these calls will "stack".
/// That is there must be as many calls to thaw as to freeze before a message is
/// actually thawed.
///
/// The ability to do `freeze`/`thaw` allows for safe transactions to change
/// tag values. For example, explicitly setting a message to have a given set of
/// tags might look like this:
///
///    try message.freeze();
///    defer message.thaw() catch {};
///
///    message.removeAllTags();
///
///    for (tags) |tag|
///        try message.addTag(tag);
///
/// With `freeze`/`thaw` used like this, the message in the database is
/// guaranteed to have either the full set of original tag values, or the full
/// set of new tag values, but nothing in between.
///
/// Imagine the example above without `freeze`/`thaw` and the operation somehow
/// getting interrupted. This could result in the message being left with no
/// tags if the interruption happened after `removeAllTags` but before `addTag`.
pub fn freeze(self: *const Message) Error!void {
    try wrap(c.notmuch_message_freeze(self.message));
}

/// Thaw the current `Message`, synchronizing any changes that may have
/// occurred while `Message` was frozen into the `notmuch` database.
///
/// See `freeze` for an example of how to use this function to
/// safely provide tag changes.
///
/// Multiple calls to `freeze`/`thaw` are valid and these calls with "stack".
/// That is there must be as many calls to `thaw` as to `freeze` before a
/// message is actually thawed.
pub fn thaw(self: *const Message) Error!void {
    try wrap(c.notmuch_message_thaw(self.message));
}

/// Deinitialize a `Message` object.
///
/// It can be useful to call this function in the case of a single query
/// object with many messages in the result, such as iterating over the entire
/// database. Otherwise, it's fine to never call this function and there will
/// still be no memory leaks. (The memory from the messages get reclaimed when
/// the containing query is deinitialized.)
pub fn deinit(self: *const Message) void {
    c.notmuch_message_destroy(self.message);
}

/// Retrieve the value for a single property key.
///
/// Returns a string owned by the `Message` or `null` if there is no such
/// key. In the case of multiple values for the given key, the first one is
/// retrieved.
pub fn getProperty(self: *const Message, key: [:0]const u8) ?[:0]const u8 {
    var value: [*c]const u8 = null;
    return switch (status(c.notmuch_message_get_property(self.message, key, &value))) {
        .success => std.mem.span(value orelse return null),
        .null_pointer => unreachable,
        else => unreachable,
    };
}

pub const AddPropertyError = error{
    /// `key` may not contain an '=' character.
    IllegalArgument,
};

/// Add a (key,value) pair to a message.
pub fn addProperty(self: *const Message, key: [:0]const u8, value: [:0]const u8) AddPropertyError!void {
    return switch (status(c.notmuch_message_add_property(self.message, key, value))) {
        .success => {},
        .null_pointer => unreachable,
        .illegal_argument => return error.IllegalArgument,
        else => unreachable,
    };
}

pub const RemovePropertyError = error{
    /// `key` may not contain an '=' character.
    IllegalArgument,
};

/// Remove a (key,value) pair from a message.
///
/// It is not an error to remove a non-existent (key,value) pair
pub fn removeProperty(self: *const Message, key: [:0]const u8, value: [:0]const u8) RemovePropertyError!void {
    return switch (status(c.notmuch_message_remove_property(self.message, key, value))) {
        .success => {},
        .null_pointer => unreachable,
        .illegal_argument => error.IllegalArgument,
        else => unreachable,
    };
}

pub const RemoveAllPropertiesError = error{
    /// Database was opened in read-only mode so message cannot be modified.
    ReadOnlyDatabase,
};

/// Remove all (key,value) pairs from the given message.
pub fn removeAllProperties(
    /// The message to operate on.
    self: *const Message,
    /// key to delete properties for. If `null`, delete properties for all keys
    key: ?[:0]const u8,
) RemoveAllPropertiesError!void {
    return switch (status(c.notmuch_message_remove_all_properties(self.message, key orelse null))) {
        .success => {},
        .read_only_database => error.ReadOnlyDatabase,
        else => unreachable,
    };
}

pub const RemoveAllPropertiesWithPrefixError = error{
    /// Database was opened in read-only mode so message cannot be modified.
    ReadOnlyDatabase,
};

/// Remove all (prefix*,value) pairs from the given message
pub fn removeAllPropertiesWithPrefix(
    /// The message to operate on.
    self: *const Message,
    /// Delete properties with keys that start with prefix. If `null`, delete all properties.
    prefix: ?[:0]const u8,
) RemoveAllPropertiesWithPrefixError!void {
    return switch (status(c.notmuch_message_remove_all_properties_with_prefix(self.message, prefix orelse null))) {
        .success => {},
        .read_only_database => error.ReadOnlyDatabase,
        else => unreachable,
    };
}

/// Get the properties for `Message`, returning a `PropertyIterator` object
/// which can be used to iterate over all properties.
///
/// The `PropertyIterator` object is owned by the message and as such, will only
/// be valid for as long as the message is valid, which is until the query from
/// which it derived is deinitialized.
pub fn getProperties(
    /// The message to examine.
    self: *const Message,
    /// Key or key prefix.
    key: [:0]const u8,
    /// If `true`, require exact match with key, otherwise treat as prefix.
    exact: bool,
) PropertiesIterator {
    return .{
        .properties = c.notmuch_message_get_properties(self.message, key, @intFromBool(exact)),
    };
}

/// Return the number of properties named "key" belonging to the specific message.
pub fn countProperties(self: *const Message, key: [:0]const u8) Error!usize {
    std.debug.assert(@typeInfo(c_uint).int.bits <= @typeInfo(usize).int.bits);
    var count: c_uint = undefined;
    try wrap(c.notmuch_message_count_properties(self.message, key, &count));
    return @intCast(count);
}

test {
    _ = std.testing.refAllDecls(@This());
}
