#!/bin/bash

# SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
# SPDX-License-Identifier: GPL-3.0-or-later

OUTPUT_DIR=$1
GIT_DIR=$2

export NOTMUCH_CONFIG="${OUTPUT_DIR}/config"
export NOTMUCH_DATABASE="${OUTPUT_DIR}/mail"
export NOTMUCH_PROFILE="zig"

cat > "$NOTMUCH_CONFIG" <<CONFIG
[database]
path=${NOTMUCH_DATABASE}
mail_root=${NOTMUCH_DATABASE}
[user]
primary_email=zig@example.org
[new]
[search]
[maildir]
CONFIG

mkdir -p "$NOTMUCH_DATABASE"
mkdir -p "$NOTMUCH_DATABASE/cur"
mkdir -p "$NOTMUCH_DATABASE/new"
mkdir -p "$NOTMUCH_DATABASE/tmp"

notmuch new --quiet

commits=$(cd "$GIT_DIR" && git log --pretty=format:%H || exit)

for commit in $commits
do
echo "$commit"
(cd "$GIT_DIR" && git -c core.pager=cat show --pretty=raw "${commit}:m") | notmuch insert
done
