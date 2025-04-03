const Message = @This();

const std = @import("std");
const log = std.log.scoped(.notmuch);

const c = @import("c.zig").c;

const Error = @import("error.zig").Error;
const wrap = @import("error.zig").wrap;

const MESSAGE_FLAG = @import("enums.zig").MESSAGE_FLAG;

const TagsIterator = @import("TagsIterator.zig");

duplicate: ?bool = null,
message: *c.notmuch_message_t,

/// Get the message ID of 'message'.
///
/// The returned string belongs to 'message' and as such, should not be
/// modified by the caller and will only be valid for as long as the message
/// is valid, (which is until the query from which it derived is destroyed).
///
/// This function will return NULL if triggers an unhandled Xapian
/// exception.
pub fn getMessageID(self: *const Message) ?[:0]const u8 {
    return std.mem.span(c.notmuch_message_get_message_id(self.message) orelse return null);
}

/// Get the thread ID of 'message'.
///
/// The returned string belongs to 'message' and as such, should not be
/// modified by the caller and will only be valid for as long as the message
/// is valid, (for example, until the user calls notmuch_message_destroy on
/// 'message' or until a query from which it derived is destroyed).
///
/// This function will return NULL if triggers an unhandled Xapian
/// exception.
pub fn getThreadID(self: *const Message) ?[:0]const u8 {
    return std.mem.span(c.notmuch_message_get_thread_id(self.message) orelse return null);
}

/// Add a tag to the given message.
pub fn addTag(self: *const Message, tag: [:0]const u8) Error!void {
    try wrap(c.notmuch_message_add_tag(self.message, tag));
}

/// Remove a tag from the given message.
pub fn removeTag(self: *const Message, tag: [:0]const u8) Error!void {
    try wrap(c.notmuch_message_add_tag(self.message, tag));
}

/// Remove all tags from the given message.
///
/// See freeze for an example showing how to safely replace tag values.
pub fn removeAllTags(self: *const Message) Error!void {
    try wrap(c.notmuch_message_remove_all_tags(self.message));
}

/// Get the tags for 'message', returning a TagsIterator object which can be
/// used to iterate over all tags.
///
/// The tags object is owned by the message and as such, will only be valid
/// for as long as the message is valid, (which is until the query from
/// which it derived is destroyed).
pub fn getTags(self: *const Message) TagsIterator {
    return .{
        .tags = c.notmuch_message_get_tags(self.message),
    };
}

/// Freeze the current state of 'message' within the database.
///
/// This means that changes to the message state, (via
/// notmuch_message_add_tag, notmuch_message_remove_tag, and
/// notmuch_message_remove_all_tags), will not be committed to the database
/// until the message is thawed with notmuch_message_thaw.
///
/// Multiple calls to freeze/thaw are valid and these calls will "stack".
/// That is there must be as many calls to thaw as to freeze before a
/// message is actually thawed.
///
/// The ability to do freeze/thaw allows for safe transactions to change tag
/// values. For example, explicitly setting a message to have a given set of
/// tags might look like this:
///
///    notmuch_message_freeze (message);
///
///    notmuch_message_remove_all_tags (message);
///
///    for (i = 0; i < NUM_TAGS; i++)
///        notmuch_message_add_tag (message, tags[i]);
///
///    notmuch_message_thaw (message);
///
/// With freeze/thaw used like this, the message in the database is
/// guaranteed to have either the full set of original tag values, or the
/// full set of new tag values, but nothing in between.
///
/// Imagine the example above without freeze/thaw and the operation somehow
/// getting interrupted. This could result in the message being left with no
/// tags if the interruption happened after notmuch_message_remove_all_tags
/// but before notmuch_message_add_tag. Get a value of a flag for the email
/// corresponding to 'message'.
pub fn freeze(self: *const Message) Error!void {
    try wrap(c.notmuch_message_freeze(self.message));
}

/// Thaw the current 'message', synchronizing any changes that may have
/// occurred while 'message' was frozen into the notmuch database.
///
/// See notmuch_message_freeze for an example of how to use this function to
/// safely provide tag changes.
///
/// Multiple calls to freeze/thaw are valid and these calls with "stack".
/// That is there must be as many calls to thaw as to freeze before a
/// message is actually thawed.
pub fn thaw(self: *const Message) Error!void {
    try wrap(c.notmuch_message_thaw(self.message));
}

/// Get a value of a flag for the email corresponding to 'message'.
pub fn getFlag(self: *const Message, flag: MESSAGE_FLAG) Error!bool {
    var is_set: c.notmuch_bool_t = undefined;
    try wrap(c.notmuch_message_get_flag_st(self.message, @intFromEnum(flag), &is_set));
    return is_set != 0;
}

/// Set a value of a flag for the email corresponding to 'message'.
pub fn setFlag(self: *const Message, flag: MESSAGE_FLAG, value: bool) void {
    c.notmuch_message_set_flag(self.message, @intFromEnum(flag), @intFromBool(value));
}

/// Get the date of 'message' as a nanosecond timestamp value.
///
/// For the original textual representation of the Date header from the
/// message call getHeader() with a header value of
/// "date".
///
/// Returns `null` in case of error.
pub fn getDate(self: *const Message) ?i128 {
    const time = c.notmuch_message_get_date(self.message);
    if (time == 0) return null;
    return time * std.time.ns_per_s;
}

/// Get the value of the specified header from 'message' as a UTF-8 string.
///
/// Common headers are stored in the database when the message is indexed and
/// will be returned from the database.  Other headers will be read from the
/// actual message file.
///
/// The header name is case insensitive.
///
/// The returned string belongs to the message so should not be modified or
/// freed by the caller (nor should it be referenced after the message is
/// destroyed).
///
/// Returns an empty string ("") if the message does not contain a header line
/// matching 'header'. Returns NULL if any error occurs.
pub fn getHeader(self: *const Message, header: [:0]const u8) ?[:0]const u8 {
    return std.mem.span(c.notmuch_message_get_header(self.message, header) orelse return null);
}

/// Retrieve the value for a single property key
///
/// Returns a string owned by the message or NULL if there is no such
/// key. In the case of multiple values for the given key, the first one
/// is retrieved.
pub fn getProperty(self: *const Message, key: [:0]const u8) Error!?[:0]const u8 {
    var value: [*c]const u8 = undefined;
    try wrap(c.notmuch_message_get_property(self.message, key, &value));
    return std.mem.span(value orelse return null);
}

/// Get the properties for *message*, returning a PropertyIterator object
/// which can be used to iterate over all properties.
///
/// The PropertyIterator object is owned by the message and as such, will
/// only be valid for as long as the message is valid, (which is until the
/// query from which it derived is destroyed).
pub fn getProperties(
    /// the message to examine
    self: *const Message,
    /// key or key prefix
    key: [:0]const u8,
    /// if true, require exact match with key, otherwise treat as prefix
    exact: bool,
) PropertyIterator {
    return .{
        .properties_ = c.notmuch_message_get_properties(self.message, key, @intFromBool(exact)),
    };
}

/// Add a (key,value) pair to a message.
pub fn addProperty(self: *const Message, key: [:0]const u8, value: [:0]const u8) Error!void {
    try wrap(c.notmuch_message_add_property(self.message, key, value));
}

/// Remove a (key,value) pair from a message.
///
/// It is not an error to remove a non-existent (key,value) pair
pub fn removeProperty(self: *const Message, key: [:0]const u8, value: [:0]const u8) Error!void {
    try wrap(c.notmuch_message_remove_property(self.message, key, value));
}

/// Remove all (key,value) pairs from the given message.
pub fn removeAllProperties(
    /// the message to operate on
    self: *const Message,
    /// key to delete properties for. If NULL, delete properties for all keys
    key: ?[:0]const u8,
) Error!void {
    try wrap(c.notmuch_message_remove_all_properties(self.message, key orelse null));
}

/// Return the number of properties named "key" belonging to the specific message.
pub fn countProperties(self: *const Message, key: [:0]const u8) Error!usize {
    var count: c_uint = undefined;
    try wrap(c.notmuch_message_count_properties(self.message, key, &count));
    return @intCast(count);
}

/// Remove all (prefix*,value) pairs from the given message
pub fn removeAllPropertiesWithPrefix(
    /// message to operate on
    self: *const Message,
    /// delete properties with keys that start with prefix. If NULL, delete all properties
    prefix: ?[:0]const u8,
) Error!void {
    try wrap(c.notmuch_message_remove_all_properties_with_prefix(self.message, prefix orelse null));
}

pub fn deinit(self: *const Message) void {
    c.notmuch_message_destroy(self.message);
}

pub const PropertyIterator = struct {
    properties_: ?*c.notmuch_message_properties_t,

    pub fn next(self: PropertyIterator) ?struct {
        key: [:0]const u8,
        value: [:0]const u8,
    } {
        const properties = self.properties_ orelse return null;
        if (c.notmuch_message_properties_valid(properties) == 0) return null;
        defer c.notmuch_message_properties_move_to_next(properties);
        return .{
            .key = std.mem.span(c.notmuch_message_properties_key(properties) orelse unreachable),
            .value = std.mem.span(c.notmuch_message_properties_value(properties) orelse unreachable),
        };
    }

    pub fn deinit(self: PropertyIterator) void {
        const properties = self.properties_ orelse return;
        c.notmuch_message_properties_destroy(properties);
    }
};
