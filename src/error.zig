const std = @import("std");

const log = std.log.scoped(.notmuch);

const c = @import("c.zig").c;

const STATUS = @import("enums.zig").STATUS;

pub const Error = error{
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

pub fn wrapMessage(rc: c.notmuch_status_t, message: [*c]const u8) Error!void {
    if (message) |msg| {
        log.err("{s}", .{msg});
        c.free(@ptrCast(@constCast(msg)));
    }
    try wrap(rc);
}

pub fn wrap(rc: c.notmuch_status_t) Error!void {
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
