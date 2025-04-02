const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("notmuch.h");
});

const log = std.log.scoped(.notmuch);

fn generateEnum(comptime prefix: []const u8) type {
    @setEvalBranchQuota(16000);
    const info = @typeInfo(c);
    var count: usize = 0;
    for (info.@"struct".decls) |d| {
        if (std.mem.eql(u8, "NOTMUCH_STATUS_LAST_STATUS", d.name)) continue;
        if (std.mem.startsWith(u8, d.name, prefix)) {
            count += 1;
        }
    }
    var fields: [count]std.builtin.Type.EnumField = undefined;
    var index: usize = 0;
    var max: c.notmuch_status_t = 0;
    for (info.@"struct".decls) |d| {
        if (std.mem.eql(u8, "NOTMUCH_STATUS_LAST_STATUS", d.name)) continue;
        if (std.mem.startsWith(u8, d.name, prefix)) {
            max = @max(max, @field(c, d.name));
            fields[index] = .{
                .name = d.name[prefix.len..],
                .value = @field(c, d.name),
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

pub const DATABASE_MODE = generateEnum("NOTMUCH_DATABASE_MODE_");
pub const DECRYPT = generateEnum("NOTMUCH_DECRYPT_");
pub const MESSAGE_FLAG = generateEnum("NOTMUCH_MESSAGE_FLAG_");
pub const STATUS = generateEnum("NOTMUCH_STATUS_");

const Error = error{
    BadQuerySyntax,
    ClosedDatabase,
    DatabaseExists,
    DuplicateMessageID,
    FailedCryptoContextCreation,
    FileError,
    FileNotEmail,
    Ignored,
    IllegalArgument,
    MaformedCryptoProtocol,
    NoConfig,
    NoDatabase,
    NoMailRoot,
    NotmuchVersion,
    NullPointer,
    OutOfMemory,
    PathError,
    ReadOnlyDatabase,
    TagTooLong,
    UnbalancedAtomic,
    UnbalancedFreezeThaw,
    UnknownCryptoProtocol,
    UnsupportedOperation,
    UpgradeRequired,
    XapianException,
};

fn wrapMessage(rc: c.notmuch_status_t, message: [*c]const u8) Error!void {
    if (message) |msg| {
        log.err("{s}", .{msg});
        c.free(@ptrCast(@constCast(msg)));
    }
    try wrap(rc);
}

fn wrap(rc: c.notmuch_status_t) Error!void {
    return switch (@as(STATUS, @enumFromInt(rc))) {
        .SUCCESS => {},
        .BAD_QUERY_SYNTAX => error.BadQuerySyntax,
        .CLOSED_DATABASE => error.ClosedDatabase,
        .DATABASE_EXISTS => error.DatabaseExists,
        .DUPLICATE_MESSAGE_ID => error.DuplicateMessageID,
        .FAILED_CRYPTO_CONTEXT_CREATION => error.FailedCryptoContextCreation,
        .FILE_ERROR => error.FileError,
        .FILE_NOT_EMAIL => error.FileNotEmail,
        .IGNORED => error.Ignored,
        .ILLEGAL_ARGUMENT => error.IllegalArgument,
        .MALFORMED_CRYPTO_PROTOCOL => error.MaformedCryptoProtocol,
        .NO_CONFIG => error.NoConfig,
        .NO_DATABASE => error.NoDatabase,
        .NO_MAIL_ROOT => error.NoMailRoot,
        .NULL_POINTER => error.NullPointer,
        .OUT_OF_MEMORY => error.OutOfMemory,
        .PATH_ERROR => error.PathError,
        .READ_ONLY_DATABASE => error.ReadOnlyDatabase,
        .TAG_TOO_LONG => error.TagTooLong,
        .UNBALANCED_ATOMIC => error.UnbalancedAtomic,
        .UNBALANCED_FREEZE_THAW => error.UnbalancedFreezeThaw,
        .UNKNOWN_CRYPTO_PROTOCOL => error.UnknownCryptoProtocol,
        .UNSUPPORTED_OPERATION => error.UnsupportedOperation,
        .UPGRADE_REQUIRED => error.UpgradeRequired,
        .XAPIAN_EXCEPTION => error.XapianException,
    };
}

pub const Database = struct {
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
    pub fn getConfigPath(self: *const Database) ?[]const u8 {
        const config = c.notmuch_config_path(self.database);
        return std.mem.span(config orelse return null);
    }
};

pub const Message = struct {
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
    pub fn getMessageID(self: *const Message) ?[]const u8 {
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

    pub fn deinit(self: *const Message) void {
        _ = c.notmuch_message_destroy(self.message);
    }
};

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

pub const TagIterator = struct {
    tags: *c.notmuch_tags_t,

    pub fn next(self: *TagIterator) ?[]const u8 {
        if (c.notmuch_tags_valid(self.tags) == 0) return null;
        defer c.notmuch_tags_move_to_next(self.tags);
        return std.mem.span(c.notmuch_tags_get(self.tags) orelse unreachable);
    }

    pub fn deinit(self: *TagIterator) void {
        c.notmuch_tags_destroy(self.tags);
    }
};

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

test {
    std.testing.refAllDeclsRecursive(@This());
}
