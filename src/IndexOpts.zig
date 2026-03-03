// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Zig wrapped around the `notmuch` C APIs that deal with index options.
const IndexOpts = @This();

const std = @import("std");

const c = @import("c");

const Decrypt = @import("enums.zig").Decrypt;
const Error = @import("error.zig").Error;
const wrap = @import("error.zig").wrap;

indexopts: *c.notmuch_indexopts_t,

/// Specify whether to decrypt encrypted parts while indexing.
///
/// Be aware that the index is likely sufficient to reconstruct the cleartext
/// of the message itself, so please ensure that the notmuch message index is
/// adequately protected. DO NOT SET THIS FLAG TO TRUE without considering the
/// security of your index.
pub fn setDecryptPolicy(self: IndexOpts, decrypt_policy: Decrypt) Error!void {
    try wrap(c.notmuch_indexopts_set_decrypt_policy(self.indexopts, @intFromEnum(decrypt_policy)));
}

/// Return whether to decrypt encrypted parts while indexing.
///
/// See `setDecryptPolicy`.
pub fn getDecryptPolicy(self: IndexOpts) Decrypt {
    return @enumFromInt(c.notmuch_indexopts_get_decrypt_policy(self.indexopts));
}

/// Deinitialize the `IndexOpts` object.
pub fn deinit(self: IndexOpts) void {
    c.notmuch_indexopts_destroy(self.indexopts);
}
