// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: GPL-3.0-or-later

//! Forces semantic analysis of every public wrapper function body.
//!
//! `refAllDecls` only references declarations; Zig never analyzes the body of
//! a function that is never called, so a wrapper that calls the wrong C
//! function — or would not compile at all — can slip through the test suite.
//! The never-taken branch below gives each wrapper a real call site without
//! executing any of them.

const notmuch = @import("notmuch.zig");

test "every wrapper body compiles" {
    var never = false;
    _ = &never;
    if (!never) return;

    try notmuch.compact("path", "backup", null, null);
    _ = notmuch.builtWith("compact");

    const db: notmuch.Database = undefined;
    _ = notmuch.Database.open(.read_only, .{});
    _ = notmuch.Database.create(.{});
    try db.close();
    try db.compact("backup", null, null);
    try db.deinit();
    _ = db.getPath();
    _ = try db.getVersion();
    _ = db.needsUpgrade();
    try db.upgrade(null, null);
    try db.beginAtomic();
    try db.endAtomic();
    _ = db.getRevision();
    _ = try db.getDirectory("path");
    try db.indexFile("file", null);
    _ = try db.indexFileGetMessage("file", null);
    try db.removeMessage("file");
    _ = try db.findMessage("id");
    _ = try db.findMessageByFilename("file");
    _ = db.getAllTags();
    var db_mut: notmuch.Database = undefined;
    try db_mut.reopen(.read_only);
    _ = try db.queryCreate("tag:inbox");
    _ = try db.queryCreateWithSyntax("tag:inbox", .xapian);
    _ = try db.configGet(.user_name);
    try db.configSet(.user_name, "value");
    const config_string = try db.configGetString("key");
    config_string.deinit();
    try db.configSetString("key", "value");
    _ = db.configGetValues(.new_tags);
    _ = db.configGetValuesString("key");
    _ = db.configGetPairs("prefix");
    _ = try db.configGetBool(.autocommit);
    _ = db.configPath();
    _ = db.getDefaultIndexOpts();

    const query: notmuch.Query = undefined;
    _ = notmuch.Query.init(undefined);
    _ = query.getQueryString();
    _ = query.getDatabase();
    query.setOmitExcluded(.all);
    query.setSort(.newest_first);
    _ = query.getSort();
    try query.addTagExclude("tag");
    _ = try query.searchThreads();
    _ = try query.searchMessages();
    _ = try query.countMessages();
    _ = try query.countThreads();
    query.deinit();

    const message: notmuch.Message = undefined;
    _ = message.getDatabase();
    _ = message.getMessageID();
    _ = message.getThreadID();
    _ = message.getReplies();
    _ = try message.countFiles();
    _ = try message.getFilename();
    _ = try message.getFilenames();
    try message.reindex(null);
    _ = try message.getFlag(.match);
    message.setFlag(.match, true);
    _ = message.getDate();
    _ = message.getHeader("Subject");
    _ = message.getTags();
    try message.addTag("tag");
    try message.removeTag("tag");
    try message.removeAllTags();
    try message.maildirFlagsToTags();
    _ = try message.hasMaildirFlag(.F);
    try message.tagsToMaildirFlags();
    try message.freeze();
    try message.thaw();
    message.deinit();
    _ = message.getProperty("key");
    try message.addProperty("key", "value");
    try message.removeProperty("key", "value");
    try message.removeAllProperties(null);
    try message.removeAllPropertiesWithPrefix(null);
    _ = message.getProperties("key", true);
    _ = try message.countProperties("key");

    const thread: notmuch.Thread = undefined;
    _ = thread.getThreadID();
    _ = thread.getTotalMessages();
    _ = thread.getTotalFiles();
    _ = thread.getToplevelMessages();
    _ = thread.getMessages();
    _ = thread.getMatchedMessages();
    _ = thread.getAuthors();
    _ = thread.getSubject();
    _ = thread.getOldestDate();
    _ = thread.getNewestDate();
    _ = thread.getTags();
    thread.deinit();

    const directory: notmuch.Directory = undefined;
    try directory.setMtime(0);
    _ = directory.getMtime();
    _ = try directory.getChildFiles();
    _ = try directory.getChildDirectories();
    try directory.delete();
    directory.deinit();

    const indexopts: notmuch.IndexOpts = undefined;
    try indexopts.setDecryptPolicy(.auto);
    _ = indexopts.getDecryptPolicy();
    indexopts.deinit();

    var message_reader: notmuch.helpers.MessageReader = undefined;
    message_reader = try notmuch.helpers.MessageReader.init(undefined, message, &.{});
    _ = message_reader.reader();
    message_reader.deinit();

    var message_writer: notmuch.helpers.MessageWriter = undefined;
    message_writer = try notmuch.helpers.MessageWriter.init(undefined, db, &.{}, .{});
    _ = message_writer.writer();
    _ = message_writer.filename();
    _ = try message_writer.finish(null);
    message_writer.cancel();

    const messages: notmuch.MessagesIterator = undefined;
    _ = messages.collectTags();
    _ = try messages.next();
    messages.deinit();

    var threads: notmuch.ThreadsIterator = undefined;
    _ = try threads.next();
    threads.deinit();

    var filenames: notmuch.FilenamesIterator = undefined;
    _ = filenames.next();
    filenames.deinit();

    var tags: notmuch.TagsIterator = undefined;
    _ = tags.next();
    tags.deinit();

    var values: notmuch.ValuesIterator = undefined;
    _ = values.next();
    values.start();
    values.deinit();

    var pairs: notmuch.PairsIterator = undefined;
    _ = pairs.next();
    pairs.deinit();

    const properties: notmuch.PropertiesIterator = undefined;
    _ = properties.next();
    properties.deinit();
}
