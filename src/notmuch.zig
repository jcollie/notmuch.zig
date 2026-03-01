// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: MIT

//! Zig bindings for the Notmuch C API.
//!
const std = @import("std");

const log = std.log.scoped(.notmuch);

pub const Error = @import("error.zig").Error;
pub const Database = @import("Database.zig");
pub const Message = @import("Message.zig");
pub const Query = @import("Query.zig");

test {
    std.testing.refAllDecls(@This());
}
