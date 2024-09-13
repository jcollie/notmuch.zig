const std = @import("std");

const c = @cImport({
    @cInclude("notmuch.h");
});

const log = std.log.scoped(.notmuch);

fn generateEnum(comptime prefix: []const u8) type {
    @setEvalBranchQuota(9000);
    const info = @typeInfo(c);
    var count: usize = 0;
    for (info.Struct.decls) |d| {
        if (std.mem.eql(u8, "NOTMUCH_STATUS_LAST_STATUS", d.name)) continue;
        if (std.mem.startsWith(u8, d.name, prefix)) {
            count += 1;
        }
    }
    var fields: [count]std.builtin.Type.EnumField = undefined;
    var index: usize = 0;
    var max: c.notmuch_status_t = 0;
    for (info.Struct.decls) |d| {
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
    return @Type(.{ .Enum = .{
        .tag_type = std.meta.Int(.unsigned, std.math.ceilPowerOfTwoAssert(u16, max)),
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
}

pub const STATUS = generateEnum("NOTMUCH_STATUS_");
pub const DATABASE_MODE = generateEnum("NOTMUCH_DATABASE_MODE_");

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

fn statusToError(comptime T: type, rc: c.notmuch_status_t, value: T) Error!T {
    return switch (@as(STATUS, @enumFromInt(rc))) {
        .SUCCESS => value,
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
    database: ?*c.notmuch_database_t = null,

    pub fn open_with_config(
        database_path: ?[*:0]const u8,
        mode: DATABASE_MODE,
        config_path: ?[:0]const u8,
        profile: ?[:0]const u8,
    ) Error!Database {
        if (!c.LIBNOTMUCH_CHECK_VERSION(5, 6, 0)) {
            log.err("need newer notmuch", .{});
            return error.NotmuchVersion;
        }

        var database: ?*c.notmuch_database_t = null;
        const rc = c.notmuch_database_open_with_config(
            if (database_path) |p| p else null,
            @intFromEnum(mode),
            if (config_path) |p| p else null,
            if (profile) |p| p else null,
            &database,
            null,
        );
        return try statusToError(Database, rc, .{ .database = database });
    }

    pub fn close(self: *const Database) void {
        _ = c.notmuch_database_close(self.database);
    }

    pub fn index_file(self: *const Database, filename: [:0]const u8, indexopts: ?*c.notmuch_indexopts_t) Error!void {
        const rc = c.notmuch_database_index_file(self.database, filename, indexopts, null);
        return try statusToError(void, rc, {});
    }

    pub fn index_file_get_message(self: *const Database, filename: [:0]const u8, indexopts: ?*c.notmuch_indexopts_t) Error!Message {
        var message: ?*c.notmuch_message_t = null;
        const rc = c.notmuch_database_index_file(self.database, filename, indexopts, &message);
        return statusToError(Message, rc, .{ .duplicate = false, .message = message }) catch |err| switch (err) {
            error.DuplicateMessageID => return .{ .duplicate = true, .message = message },
            else => |e| return e,
        };
    }

    pub fn find_message_by_filename(self: *const Database, filename: [:0]const u8) Error!Message {
        var message: ?*c.notmuch_message_t = null;
        const rc = c.notmuch_database_find_message_by_filename(self.database, filename, &message);
        return try statusToError(Message, rc, .{ .message = message });
    }

    pub fn remove_message(self: *const Database, filename: [:0]const u8) Error!void {
        const rc = c.notmuch_database_remove_message(self.database, filename);
        return try statusToError(void, rc, {});
    }
};

pub const Message = struct {
    duplicate: ?bool = null,
    message: ?*c.notmuch_message_t = null,

    pub fn add_tag(self: *const Message, tag: [:0]const u8) Error!void {
        const rc = c.notmuch_message_add_tag(self.message, tag);
        return try statusToError(void, rc, {});
    }

    pub fn deinit(self: *const Message) void {
        _ = c.notmuch_message_destroy(self.message);
    }
};
