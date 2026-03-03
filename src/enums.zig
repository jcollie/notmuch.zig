// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

const c = @import("c");

/// Generate Zig enums from C enums that begin with a prefix. Skip creating
/// enums for certain names.
fn generateEnum(comptime prefix: []const u8, skips: []const []const u8) type {
    @setEvalBranchQuota(24000);
    const info = @typeInfo(c);
    var count = 0;
    var max = 0;
    outer: for (info.@"struct".decls) |decl| {
        for (skips) |skip| if (std.mem.eql(u8, skip, decl.name)) continue :outer;
        if (std.mem.startsWith(u8, decl.name, prefix)) {
            max = @max(max, @field(c, decl.name));
            count += 1;
        }
    }
    const TagType = std.math.IntFittingRange(0, max);
    var field_names: [count][]const u8 = undefined;
    var field_values: [count]TagType = undefined;
    var index = 0;
    outer: for (info.@"struct".decls) |decl| {
        for (skips) |skip| if (std.mem.eql(u8, skip, decl.name)) continue :outer;
        if (std.mem.cutPrefix(u8, decl.name, prefix)) |suffix| {
            var buf: [suffix.len]u8 = undefined;
            field_names[index] = std.ascii.lowerString(&buf, suffix);
            field_values[index] = @field(c, decl.name);
            index += 1;
        }
    }
    return @Enum(
        TagType,
        .exhaustive,
        &field_names,
        &field_values,
    );
}

fn checkEnum(comptime E: type, comptime prefix: []const u8, comptime skips: []const []const u8) void {
    @setEvalBranchQuota(24000);

    const e_fields = @typeInfo(E).@"enum".fields;
    const c_decls = @typeInfo(c).@"struct".decls;

    loop: for (c_decls) |decl| {
        for (skips) |skip| if (std.mem.eql(u8, skip, decl.name)) continue :loop;
        const suffix = std.mem.cutPrefix(u8, decl.name, prefix) orelse continue :loop;
        var b: [suffix.len]u8 = undefined;
        const s = std.ascii.lowerString(&b, suffix);
        if (@hasField(E, s)) continue :loop;
        @panic(std.fmt.comptimePrint("{s} is missing a value {s}", .{ @typeName(E), s }));
    }
    for (e_fields) |field| {
        var buf: [prefix.len + field.name.len]u8 = undefined;
        @memcpy(buf[0..prefix.len], prefix);
        _ = std.ascii.upperString(buf[prefix.len..], field.name);
        if (!@hasDecl(c, &buf)) @panic(std.fmt.comptimePrint("{s} has a value {s} without a matching C value {s}.", .{ @typeName(E), field.name, &buf }));
        if (field.value != @field(c, &buf)) @panic(std.fmt.comptimePrint(
            "{s} value {s}({d}) != c.{s}({d}).",
            .{
                @typeName(E),
                field.name,
                field.value,
                &buf,
                @field(c, &buf),
            },
        ));
    }
}

/// Configuration keys known to notmuch.
pub const Config = enum(u4) {
    database_path = c.NOTMUCH_CONFIG_DATABASE_PATH,
    mail_root = c.NOTMUCH_CONFIG_MAIL_ROOT,
    hook_dir = c.NOTMUCH_CONFIG_HOOK_DIR,
    backup_dir = c.NOTMUCH_CONFIG_BACKUP_DIR,
    exclude_tags = c.NOTMUCH_CONFIG_EXCLUDE_TAGS,
    new_tags = c.NOTMUCH_CONFIG_NEW_TAGS,
    new_ignore = c.NOTMUCH_CONFIG_NEW_IGNORE,
    sync_maildir_flags = c.NOTMUCH_CONFIG_SYNC_MAILDIR_FLAGS,
    primary_email = c.NOTMUCH_CONFIG_PRIMARY_EMAIL,
    other_email = c.NOTMUCH_CONFIG_OTHER_EMAIL,
    user_name = c.NOTMUCH_CONFIG_USER_NAME,
    autocommit = c.NOTMUCH_CONFIG_AUTOCOMMIT,
    extra_headers = c.NOTMUCH_CONFIG_EXTRA_HEADERS,
    index_as_text = c.NOTMUCH_CONFIG_INDEX_AS_TEXT,
    authors_separator = c.NOTMUCH_CONFIG_AUTHORS_SEPARATOR,
    authors_matched_separator = c.NOTMUCH_CONFIG_AUTHORS_MATCHED_SEPARATOR,
    // git_fail_on_missing = c.NOTMUCH_CONFIG_GIT_FAIL_ON_MISSING,
    // git_metadata_prefix = c.NOTMUCH_CONFIG_GIT_METADATA_PREFIX,
    // git_ref = c.NOTMUCH_CONFIG_GIT_REF,

    comptime {
        checkEnum(@This(), "NOTMUCH_CONFIG_", &.{ "NOTMUCH_CONFIG_FIRST", "NOTMUCH_CONFIG_LAST" });
    }
};

pub const DatabaseMode = enum(u1) {
    read_only = c.NOTMUCH_DATABASE_MODE_READ_ONLY,
    read_write = c.NOTMUCH_DATABASE_MODE_READ_WRITE,

    comptime {
        checkEnum(@This(), "NOTMUCH_DATABASE_MODE_", &.{});
    }
};

/// Stating a policy about how to decrypt messages.
pub const Decrypt = enum(u2) {
    false = c.NOTMUCH_DECRYPT_FALSE,
    true = c.NOTMUCH_DECRYPT_TRUE,
    auto = c.NOTMUCH_DECRYPT_AUTO,
    nostash = c.NOTMUCH_DECRYPT_NOSTASH,

    comptime {
        checkEnum(@This(), "NOTMUCH_DECRYPT_", &.{});
    }
};

/// Exclude values for `Query.setOmitExcluded`
pub const Exclude = generateEnum("NOTMUCH_EXCLUDE_", &.{});

pub const MessageFlag = enum(u2) {
    match = c.NOTMUCH_MESSAGE_FLAG_MATCH,
    excluded = c.NOTMUCH_MESSAGE_FLAG_EXCLUDED,
    /// This message is a "ghost message", meaning it has no filenames or
    /// content, but we know it exists because it was referenced by some other
    /// message. A ghost message has only a message ID and thread ID.
    ghost = c.NOTMUCH_MESSAGE_FLAG_GHOST,

    comptime {
        checkEnum(@This(), "NOTMUCH_MESSAGE_FLAG_", &.{});
    }
};

pub const MaildirFlag = enum(u8) {
    /// Adds the "draft" tag to the message.
    D = 'D',
    /// Adds the "flagged" tag to the message.
    F = 'F',
    /// Adds the "passed" tag to the message.
    P = 'P',
    /// Adds the "replied" tag to the message.
    R = 'R',
    /// Removes the "unread" tag from the message.
    S = 'S',
};

/// query syntax
pub const QuerySyntax = generateEnum("NOTMUCH_QUERY_SYNTAX_", &.{});

/// Sort values for notmuch_query_set_sort.
pub const Sort = generateEnum("NOTMUCH_SORT_", &.{});

/// Status codes used for the return values of most functions.
pub const Status = enum(u5) {
    /// No error occurred.
    success = c.NOTMUCH_STATUS_SUCCESS,
    /// Out of memory.
    out_of_memory = c.NOTMUCH_STATUS_OUT_OF_MEMORY,
    /// An attempt was made to write to a database opened in read-only
    /// mode.
    read_only_database = c.NOTMUCH_STATUS_READ_ONLY_DATABASE,
    /// A Xapian exception occurred.
    xapian_exception = c.NOTMUCH_STATUS_XAPIAN_EXCEPTION,
    /// An error occurred trying to read or write to a file (this could be file not
    /// found, permission denied, etc.)
    file_error = c.NOTMUCH_STATUS_FILE_ERROR,
    /// A file was presented that doesn't appear to be an email message.
    file_not_email = c.NOTMUCH_STATUS_FILE_NOT_EMAIL,
    /// A file contains a message ID that is identical to a message already in the
    /// database.
    duplicate_message_id = c.NOTMUCH_STATUS_DUPLICATE_MESSAGE_ID,
    /// The user erroneously passed a `null` pointer to a notmuch function.
    null_pointer = c.NOTMUCH_STATUS_NULL_POINTER,
    /// A tag value is too long (exceeds NOTMUCH_TAG_MAX).
    tag_too_long = c.NOTMUCH_STATUS_TAG_TOO_LONG,
    /// The `Message.thaw` function has been called more times than
    /// `Message.freeze`.
    unbalanced_freeze_thaw = c.NOTMUCH_STATUS_UNBALANCED_FREEZE_THAW,
    /// `Database.endAtomic` has been called more times than `Database.beginAtomic`.
    unbalanced_atomic = c.NOTMUCH_STATUS_UNBALANCED_ATOMIC,
    /// The operation is not supported.
    unsupported_operation = c.NOTMUCH_STATUS_UNSUPPORTED_OPERATION,
    /// The operation requires a database upgrade.
    upgrade_required = c.NOTMUCH_STATUS_UPGRADE_REQUIRED,
    /// There is a problem with the proposed path, e.g. a relative path passed to a
    /// function expecting an absolute path.
    path_error = c.NOTMUCH_STATUS_PATH_ERROR,
    /// The requested operation was ignored. Depending on the function, this may not
    /// be an actual error.
    ignored = c.NOTMUCH_STATUS_IGNORED,
    /// One of the arguments violates the preconditions for the function, in a way
    /// not covered by a more specific argument.
    illegal_argument = c.NOTMUCH_STATUS_ILLEGAL_ARGUMENT,
    /// A MIME object claimed to have cryptographic protection which notmuch tried
    /// to handle, but the protocol was not specified in an intelligible way.
    malformed_crypto_protocol = c.NOTMUCH_STATUS_MALFORMED_CRYPTO_PROTOCOL,
    /// Notmuch attempted to do crypto processing, but could not initialize the
    /// engine needed to do so.
    failed_crypto_context_creation = c.NOTMUCH_STATUS_FAILED_CRYPTO_CONTEXT_CREATION,
    /// A MIME object claimed to have cryptographic protection, and notmuch
    /// attempted to process it, but the specific protocol was something that
    /// notmuch doesn't know how to handle.
    unknown_crypto_protocol = c.NOTMUCH_STATUS_UNKNOWN_CRYPTO_PROTOCOL,
    /// Unable to load a config file
    no_config = c.NOTMUCH_STATUS_NO_CONFIG,
    /// Unable to load a database.
    no_database = c.NOTMUCH_STATUS_NO_DATABASE,
    /// Database exists, so not (re)-created.
    database_exists = c.NOTMUCH_STATUS_DATABASE_EXISTS,
    /// Syntax error in query.
    bad_query_syntax = c.NOTMUCH_STATUS_BAD_QUERY_SYNTAX,
    /// No mail root could be deduced from parameters and environment.
    no_mail_root = c.NOTMUCH_STATUS_NO_MAIL_ROOT,
    /// Database is not fully opened, or has been closed.
    closed_database = c.NOTMUCH_STATUS_CLOSED_DATABASE,
    /// The iterator being examined has been exhausted and contains no more items.
    iterator_exhausted = c.NOTMUCH_STATUS_ITERATOR_EXHAUSTED,
    /// An operation that was being performed on the database has been invalidated
    /// while in progress, and must be re-executed. This will typically happen
    /// while iterating over query results and the underlying Xapian database is
    /// modified by another process so that the currently open version cannot be
    /// read anymore.
    operation_invalidated = c.NOTMUCH_STATUS_OPERATION_INVALIDATED,

    pub fn init(rc: c.notmuch_status_t) Status {
        return @enumFromInt(rc);
    }

    comptime {
        checkEnum(@This(), "NOTMUCH_STATUS_", &.{"NOTMUCH_STATUS_LAST_STATUS"});
    }
};

/// Convenience function to convert a notmuch API return code to a Status enum.
pub fn status(rc: c.notmuch_status_t) Status {
    return .init(rc);
}
