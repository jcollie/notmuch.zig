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

The narrowed error sets are based on the status codes each function documents,
plus the undocumented ones it has been observed to return in practice (for
example, opening a missing database yields `error.NoDatabase`). Because
`libnotmuch` can still surprise — a newer version may add status codes, and
operations on a closed database return codes no function documents — every
narrowed set also includes `error.Unexpected` as a catch-all, so an
undocumented status surfaces as a recoverable error rather than a crash.

> **Status:** early. The API still changes without notice. All of the current
> (non-deprecated) `libnotmuch` API is wrapped.

## Requirements

- Zig 0.17.0 or newer (for Zig 0.16, use the `zig-0.16` branch or the
  `0.3.0` tag)
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
$ zig fetch --save git+https://git.jcollie.dev/jeff/notmuch.zig#main
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

The one Zig dependency, fetched by the build system, is
[zig-maildir](https://git.jcollie.dev/jeff/zig-maildir): notmuch indexes a
maildir but does not write one, so the helpers that put mail *into* the store
deliver through it rather than inventing filenames and rename dances of their
own. It is re-exported as `notmuch.maildir`.

## Where this lives

The repository is hosted on Forgejo at
<https://git.jcollie.dev/jeff/notmuch.zig>, and mirrored on
[Tangled](https://tangled.org/jcollie.dev/notmuch.zig), on
[GitHub](https://github.com/jcollie/notmuch.zig), and on Radicle, which the
next section covers.

```console
$ git clone https://git.jcollie.dev/jeff/notmuch.zig.git
```

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

### Helpers

Beyond the wrappers, `notmuch.helpers` composes the bindings with the Zig
standard library. `MessageWriter` streams an email into the mail store through
a `std.Io.Writer` and indexes it, delivering it the way a maildir has to be
written — into `tmp` under a name nothing else will invent, synced, and
renamed into `new` or `cur` once it is whole — so a reader of the store never
sees a partial message, and `cancel` removes the half-written file without a
trace. `MessageReader` reads a message's raw content back through a
`std.Io.Reader`:

```zig
var buffer: [4096]u8 = undefined;

var mw = try notmuch.helpers.MessageWriter.init(io, db, &buffer, .{ .to = .new });
try mw.writer().print("Message-ID: <{s}>\r\n\r\nHello!\r\n", .{message_id});
const message = try mw.finish(null);
defer message.deinit();

var mr = try notmuch.helpers.MessageReader.init(io, message, &buffer);
defer mr.deinit();
const content = try mr.reader().allocRemaining(allocator, .unlimited);
defer allocator.free(content);
```

A message that is already read, or a draft, is delivered straight into `cur`
with the maildir flags it carries — which notmuch then reads back as flags:

```zig
var mw = try notmuch.helpers.MessageWriter.init(io, db, &buffer, .{
    .to = .{ .cur = .{ .seen = true, .draft = true } },
});
```

### What's available

| Type | Covers |
| --- | --- |
| `notmuch.Database` | opening, creating, closing, upgrading and compacting databases; configuration-only loading; atomic sections; revisions; indexing and removing files; message lookup; directory lookup; typed and string-keyed configuration access, values and pairs; status strings |
| `notmuch.Query` | query strings and syntax, sort order, tag exclusions, message and thread searches, result counts |
| `notmuch.Message` | message and thread IDs, headers, dates, filenames, flags, tags, maildir flag synchronization, properties, freeze/thaw, reindexing |
| `notmuch.Thread` | thread ID, subject, authors, oldest/newest dates, message and file counts, contained messages, tags |
| `notmuch.Directory` | directory mtimes, child files and subdirectories, deletion |
| `notmuch.IndexOpts` | indexing options, including the decryption policy |
| `notmuch.MessagesIterator`, `notmuch.ThreadsIterator`, `notmuch.FilenamesIterator` | iteration over search results |
| `notmuch.TagsIterator`, `notmuch.PropertiesIterator`, `notmuch.PairsIterator`, `notmuch.ValuesIterator` | iteration over tags, message properties, and configuration data |
| `notmuch.Error` | the full set of `notmuch_status_t` codes as Zig errors, plus `error.Unexpected` for status codes a function is not documented to return |
| `notmuch.Status` | the raw `notmuch_status_t` codes as a Zig enum, with libnotmuch's human-readable descriptions via `toString` |
| `notmuch.compact`, `notmuch.builtWith`, `notmuch.tag_max` | module-level helpers |
| `notmuch.helpers.MessageWriter`, `notmuch.helpers.MessageReader` | streaming an email through a `std.Io.Writer` into the mail store and indexing it, and reading a message's raw content through a `std.Io.Reader` (conveniences unique to these bindings) |
| `notmuch.maildir` | [zig-maildir](https://git.jcollie.dev/jeff/zig-maildir), re-exported: delivery destinations and maildir flags for `helpers.MessageWriter`, and direct manipulation of the mail store itself |

Full API documentation is generated from the source and published at
<https://jeff.jcollie.page/notmuch.zig/>. To read it locally instead:

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

The suite exercises the bindings against real notmuch databases built in
temporary directories from a small embedded email corpus (`src/testing.zig`).
The corpus is delivered into a real maildir through zig-maildir rather than
copied into `cur` by hand, so the messages carry generated names and the tests
name them by `Message-ID`.
Usage-example tests sit next to the functions they exercise as doctests, so
they double as examples in the generated API documentation; edge cases and
error paths live in `src/tests.zig`. A compile-check test
(`src/compile_check.zig`) gives every public wrapper a real call site, since
Zig never analyzes the body of a function that is never called.

`test/build-archive.sh` builds a throwaway notmuch database from a git
repository's commit log, which is useful for exercising the bindings against
larger volumes of real mail-shaped data.

The project is [REUSE](https://reuse.software/) compliant; `reuse lint` checks
that every file carries copyright and licensing information.

## License

GPL-3.0-or-later. See the [`LICENSES`](LICENSES) directory for the full texts.
