// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Message indexing options, obtained from `Database.getDefaultIndexOpts`
//! and passed to `Database.indexFile` and `Message.reindex`.
//!
//! Currently the only option is the decryption policy
//! (`setDecryptPolicy`/`getDecryptPolicy`).
const IndexOpts = @This();

const std = @import("std");

const c = @import("c");

pub const Decrypt = @import("enums.zig").Decrypt;
const Error = @import("error.zig").Error;
const wrap = @import("error.zig").wrap;

/// The underlying `notmuch_indexopts_t` handle; only needed directly when
/// calling libnotmuch C APIs these bindings do not wrap.
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
