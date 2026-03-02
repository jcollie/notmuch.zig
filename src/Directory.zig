// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Zig wrapper around the `notmuch` directory APIs.

const Directory = @This();

const std = @import("std");
const log = std.log.scoped(.notmuch);

const c = @import("c");

const Error = @import("error.zig").Error;
const wrap = @import("error.zig").wrap;

directory: *c.notmuch_directory_t,
