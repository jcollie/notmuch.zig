<!-- SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# notmuch.zig

Zig bindings for the [notmuch](https://notmuchmail.org/) mail indexer's C
library, `libnotmuch`.

The bindings wrap the C API in idiomatic Zig: opaque C pointers become structs
with methods, `notmuch_status_t` return codes become Zig error sets (narrowed
per function, so you only handle the errors a given call can actually return),
C enums become Zig enums that are checked against the header at compile time,
and the various `notmuch_*_t` list types become iterators with a `next` method.

> **Status:** early. The API still changes without notice, and not every part
> of `libnotmuch` is wrapped yet.

## Requirements

- Zig 0.16.0-dev.2682+02142a54d or newer
- `libnotmuch` 5.6 or newer (notmuch 0.32+), including its headers

`build.zig` links `notmuch` as a system library and runs `translate-c` over
`notmuch.h`. If the header is not on the default include path, point at it with
the `NOTMUCH_INCLUDE` environment variable:

```console
$ export NOTMUCH_INCLUDE=/usr/include
```

## Installation

Add the package to your project:

```console
$ zig fetch --save git+https://git.ocjtech.us/jeff/notmuch.zig#main
```

Then wire the module up in your `build.zig`:

```zig
const notmuch = b.dependency("notmuch", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("notmuch", notmuch.module("notmuch"));
```

The module links `libnotmuch` and libc itself, so there is nothing else to add.

## Cloning with Radicle

The repository is also published on the [Radicle](https://radicle.xyz/)
peer-to-peer network under the repository ID

```
rad:zQWqvMomwbxzKg6pd4ktY65B8oyY
```

With a local Radicle node running, clone it with:

```console
$ rad clone rad:zQWqvMomwbxzKg6pd4ktY65B8oyY
```

That fetches the repository, checks out the default branch, and starts seeding
it so other peers can fetch from you. To follow the repository without checking
out a working copy, use `rad seed` instead:

```console
$ rad seed rad:zQWqvMomwbxzKg6pd4ktY65B8oyY
```

If you already have a clone from one of the other remotes, you can attach it to
the same Radicle repository instead of cloning again:

```console
$ git remote add rad rad://zQWqvMomwbxzKg6pd4ktY65B8oyY
$ git fetch rad
```

## Usage

Opening a database returns a tagged union rather than an error union, because
`libnotmuch` supplies a human-readable message alongside the status code and
that message has to be freed:

```zig
const std = @import("std");
const notmuch = @import("notmuch");

pub fn main() !void {
    // With no options, the database and config locations are taken from the
    // environment ($NOTMUCH_DATABASE, $NOTMUCH_CONFIG, $NOTMUCH_PROFILE) and
    // the usual notmuch configuration files.
    const db = switch (notmuch.Database.open(.read_only, .{})) {
        .ok => |db| db,
        .err => |e| {
            defer e.deinit();
            std.log.err("unable to open database: {s}", .{e.message() orelse "unknown error"});
            return e.err;
        },
    };
    defer db.deinit() catch |err| std.log.err("unable to close database: {t}", .{err});

    const query = try db.queryCreate("tag:inbox");
    defer query.deinit();
    query.setSort(.newest_first);

    var messages = try query.searchMessages();
    defer messages.deinit();

    while (try messages.next()) |message| {
        defer message.deinit();

        const subject = message.getHeader("Subject") orelse "(no subject)";
        std.debug.print("{s}\n", .{subject});

        var tags = message.getTags();
        defer tags.deinit();
        while (tags.next()) |tag| std.debug.print("  +{s}\n", .{tag});
    }
}
```

Everything returned by a query — messages, threads, tags, filenames — is owned
by the object it came from, so the `deinit` calls above are optional; they just
release memory sooner than the enclosing query would.

### What's available

| Type | Covers |
| --- | --- |
| `notmuch.Database` | opening, creating, closing, upgrading and compacting databases; atomic sections; indexing and removing files; message lookup; configuration keys and values |
| `notmuch.Query` | query strings and syntax, sort order, tag exclusions, message and thread searches, result counts |
| `notmuch.Message` | message and thread IDs, headers, dates, filenames, flags, tags, maildir flag synchronization, properties, freeze/thaw, reindexing |
| `notmuch.Thread` | thread ID, subject, authors, oldest/newest dates, message and file counts, contained messages, tags |
| `notmuch.MessagesIterator`, `notmuch.ThreadsIterator`, `notmuch.FilenamesIterator` | iteration over search results |
| `notmuch.Error` | the full set of `notmuch_status_t` codes as Zig errors |
| `notmuch.compact`, `notmuch.builtWith`, `notmuch.tag_max` | module-level helpers |

Full API documentation is generated from the source and published at
<https://notmuch-zig.ocjtech.us>. To read it locally instead:

```console
$ zig build docs
$ xdg-open zig-out/docs/index.html
```

## Development

A Nix flake provides a development shell with Zig, notmuch, and the linting
tools, and sets `NOTMUCH_INCLUDE` for you:

```console
$ nix develop
```

Run the test suite with:

```console
$ zig build test
```

`test/build-archive.sh` builds a throwaway notmuch database from a git
repository's commit log, which is useful for exercising the bindings against
real mail-shaped data.

The project is [REUSE](https://reuse.software/) compliant; `reuse lint` checks
that every file carries copyright and licensing information.

## License

GPL-3.0-or-later. See the [`LICENSES`](LICENSES) directory for the full texts.
