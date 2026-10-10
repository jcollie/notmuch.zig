<!-- SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Changelog

Notable changes to notmuch.zig. The format is loosely
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the versions are
[semantic](https://semver.org/) — while the major version is 0, a breaking
change raises the minor.

## 0.4.0

### Changed

- **Zig 0.17.0 is required.** The bindings are ported to the released 0.17
  compiler and standard library, and no longer build with 0.16. The 0.16
  version is kept on the `zig-0.16` branch, starting from the `0.3.0` tag.
- zig-maildir moves to 0.2.0, its first Zig 0.17 version.

## 0.3.0

### Fixed

- **An iterator no longer panics when notmuch declines to build an item.**
  `ThreadsIterator.next` and `MessagesIterator.next` asked `notmuch_threads_get`
  and `notmuch_messages_get` for the item at the cursor and wrote
  `orelse unreachable`, on the reasoning that `notmuch_*_valid` had just said
  there was one. That is not a guarantee libnotmuch makes: the item is built
  out of the database when it is asked for, and the header says plainly that
  NULL comes back if the build fails. Both now return
  `error.XapianException`.

  It is reachable on any archive that is read while it is written. A writer
  committing underneath a running search invalidates the reader, the next item
  fails to build, and a daemon serving that search died on the spot — about
  once a minute under a search load with deliveries running alongside it.

### Changed

- `ThreadsIterator.NextError` and `MessagesIterator.NextError` gained
  `XapianException`. **This is why the minor version moved**: an exhaustive
  `switch` over either set no longer compiles. A caller that propagates with
  `try`, or switches with an `else`, is unaffected.

  It is reported as a Xapian exception rather than as `OutOfMemory`, which is
  the only cause libnotmuch's header names, because the allocator is rarely
  the real one — and a caller that treats running out of memory as fatal would
  give up on something it should have retried. `Directory` already maps a NULL
  return the same way.

## 0.2.0 and earlier

Not recorded here; see the commit history.
