# Copyright (c) 2026 Maja Błaszczak
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
DIST_DIR="$SRC_DIR/dist"

LOG()
{
    echo -E "$*"
}

LOGE()
{
    echo -E "Error: $*" >&2
}

LOGW()
{
    echo -E "Warning: $*" >&2
}

UNKNOWN_OPTION()
{
    LOGE "Unknown option: $1"
    PRINT_USAGE >&2
    exit 1
}

PREPARE_BUILD()
{
    cd "$SRC_DIR" || exit 1
    GIT_HASH="$(git rev-parse --short HEAD 2> /dev/null)" || GIT_HASH="unknown"
    mkdir -p "$DIST_DIR" || exit 1
}

BUILD_LINUX_BUNDLE()
{
    LOG "Building Flutter Linux bundle"
    flutter build linux --release "--dart-define=GIT_HASH=$GIT_HASH"
}

COPY_ARTIFACT()
{
    local SOURCE="$1"
    local NAME="$2"

    if [ ! -f "$SOURCE" ]; then
        LOGE "Build output missing: $SOURCE"
        return 1
    fi

    cp "$SOURCE" "$DIST_DIR/$NAME"
}
