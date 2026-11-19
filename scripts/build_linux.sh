#!/usr/bin/env bash
# Copyright (c) 2026 Maja Błaszczak
# SPDX-License-Identifier: GPL-3.0-or-later

# [
# shellcheck source=scripts/utils/build_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/utils/build_utils.sh" || exit 1

BUILD_ARCH=false
BUILD_APPIMAGE=false
PACKAGE_ARGS=("--package-only")

PRINT_USAGE()
{
    echo "Usage: build_linux.sh [options]"
    echo "     --tar : Build the standalone tarball (default)"
    echo "     --arch : Also build the Arch Linux package"
    echo "     --appimage : Also build the AppImage"
    echo "     --all : Build all three packages"
    echo " -r, --release : Use release package metadata for Arch"
    echo " -h, --help : Show this help"
}

PREPARE_SCRIPT()
{
    while [ "$#" != 0 ]; do
        if [[ "$1" == "--tar" ]]; then
            :
        elif [[ "$1" == "--arch" ]]; then
            BUILD_ARCH=true
        elif [[ "$1" == "--appimage" ]]; then
            BUILD_APPIMAGE=true
        elif [[ "$1" == "--all" ]]; then
            BUILD_ARCH=true
            BUILD_APPIMAGE=true
        elif [[ "$1" == "-r" ]] || [[ "$1" == "--release" ]]; then
            PACKAGE_ARGS+=("--release")
        elif [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
            PRINT_USAGE
            exit 0
        else
            UNKNOWN_OPTION "$1"
        fi
        shift
    done
}
# ]

PREPARE_SCRIPT "$@"
PREPARE_BUILD

BUILD_LINUX_BUNDLE || exit 1
TAR_NAME="aira-$GIT_HASH-linux-x64.tar.gz"
LOG "Creating Linux tarball in dist/"
tar -czf "$DIST_DIR/$TAR_NAME" -C "build/linux/x64/release/bundle" "." || exit 1

if $BUILD_ARCH; then
    "$SRC_DIR/scripts/build_arch.sh" "${PACKAGE_ARGS[@]}" || exit 1
fi

if $BUILD_APPIMAGE; then
    "$SRC_DIR/scripts/build_appimage.sh" "${PACKAGE_ARGS[@]}" || exit 1
fi

exit 0
