// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

const log = std.log.scoped(.notmuch);

const c = @import("c");

const Status = @import("enums.zig").Status;
const status = @import("enums.zig").status;

pub const Error = error{
    /// Syntax error in query.
    BadQuerySyntax,
    /// Database is not fully opened, or has been closed.
    ClosedDatabase,
    /// Database already exists, so not (re-)created.
    DatabaseExists,
    /// A file contains a message ID that is identical to a message already in
    /// the database.
    DuplicateMessageID,
    /// Notmuch attempted to do crypto processing, but could not initialize the
    /// engine needed to do so.
    FailedCryptoContextCreation,
    /// An error occurred trying to read or write to a file (this could be file
    /// not found, permission denied, etc.)
    FileError,
    /// A file was presented that doesn't appear to be an email message.
    FileNotEmail,
    /// There was an error determining the database format version.
    FormatVersionError,
    /// The requested operation was ignored. Depending on the function, this may
    /// not be an actual error.
    Ignored,
    /// One of the arguments violates the preconditions for the function, in a
    /// way not covered by a more specific argument.
    IllegalArgument,
    /// The iterator being examined has been exhausted and contains no more
    /// items.
    IteratorExhausted,
    /// A MIME object claimed to have cryptographic protection which notmuch
    /// tried to handle, but the protocol was not specified in an intelligible
    /// way.
    MaformedCryptoProtocol,
    /// Unable to load a config file.
    NoConfig,
    /// Unable to load a database.
    NoDatabase,
    /// No mail root could be deduced from parameters and environment.
    NoMailRoot,
    /// A newer version of the notmuch library is required.
    NotmuchVersion,
    /// The user erroneously passed a NULL pointer to a notmuch function.
    NullPointer,
    /// An operation that was being performed on the database has been
    /// invalidated while in progress, and must be re-executed.
    ///
    /// This will typically happen while iterating over query results and the
    /// underlying Xapian database is modified by another process so that the
    /// currently open version cannot be read anymore.
    OperationInvalidated,
    /// Out of memory.
    OutOfMemory,
    /// There is a problem with the proposed path, e.g. a relative path passed
    /// to a function expecting an absolute path.
    PathError,
    /// An attempt was made to write to a database opened in read-only mode.
    ReadOnlyDatabase,
    /// A tag value is too long (exceeds NOTMUCH_TAG_MAX).
    TagTooLong,
    /// notmuch_database_end_atomic has been called more times than
    /// notmuch_database_begin_atomic.
    UnbalancedAtomic,
    /// The notmuch_message_thaw function has been called more times than
    /// notmuch_message_freeze.
    UnbalancedFreezeThaw,
    /// A MIME object claimed to have cryptographic protection, and notmuch
    /// attempted to process it, but the specific protocol was something that
    /// notmuch doesn't know how to handle.
    UnknownCryptoProtocol,
    /// The operation is not supported.
    UnsupportedOperation,
    /// The operation requires a database upgrade.
    UpgradeRequired,
    /// A Xapian exception occurred.
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
    return switch (status(rc)) {
        .success => {},
        .bad_query_syntax => error.BadQuerySyntax,
        .closed_database => error.ClosedDatabase,
        .database_exists => error.DatabaseExists,
        .duplicate_message_id => error.DuplicateMessageID,
        .failed_crypto_context_creation => error.FailedCryptoContextCreation,
        .file_error => error.FileError,
        .file_not_email => error.FileNotEmail,
        .ignored => error.Ignored,
        .illegal_argument => error.IllegalArgument,
        .iterator_exhausted => error.IteratorExhausted,
        .malformed_crypto_protocol => error.MaformedCryptoProtocol,
        .no_config => error.NoConfig,
        .no_database => error.NoDatabase,
        .no_mail_root => error.NoMailRoot,
        .null_pointer => error.NullPointer,
        .operation_invalidated => error.OperationInvalidated,
        .out_of_memory => error.OutOfMemory,
        .path_error => error.PathError,
        .read_only_database => error.ReadOnlyDatabase,
        .tag_too_long => error.TagTooLong,
        .unbalanced_atomic => error.UnbalancedAtomic,
        .unbalanced_freeze_thaw => error.UnbalancedFreezeThaw,
        .unknown_crypto_protocol => error.UnknownCryptoProtocol,
        .unsupported_operation => error.UnsupportedOperation,
        .upgrade_required => error.UpgradeRequired,
        .xapian_exception => error.XapianException,
    };
}

test wrap {
    try wrap(c.NOTMUCH_STATUS_SUCCESS);
    try std.testing.expectError(error.BadQuerySyntax, wrap(c.NOTMUCH_STATUS_BAD_QUERY_SYNTAX));
}
