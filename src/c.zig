// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: MIT

pub const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("notmuch.h");
});
