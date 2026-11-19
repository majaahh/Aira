#!/usr/bin/env bash
# Copyright (c) 2026 Maja Błaszczak
# SPDX-License-Identifier: GPL-3.0-or-later

# [
# shellcheck source=scripts/utils/build_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/utils/build_utils.sh" || exit 1

IS_RELEASE=false
PACKAGE_ONLY=false

PRINT_USAGE()
{
    echo "Usage: build_arch.sh [options]"
    echo " -r, --release : Use release package metadata"
    echo "     --package-only : Package an existing Flutter Linux bundle"
    echo " -h, --help : Show this help"
}

PREPARE_SCRIPT()
{
    while [ "$#" != 0 ]; do
        if [[ "$1" == "-r" ]] || [[ "$1" == "--release" ]]; then
            IS_RELEASE=true
        elif [[ "$1" == "--package-only" ]]; then
            PACKAGE_ONLY=true
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

if ! $PACKAGE_ONLY; then
    BUILD_LINUX_BUNDLE || exit 1
fi

LOG "Building Arch Linux package"
cd "$SRC_DIR/packaging/linux" || exit 1
export IS_RELEASE
export PKGDEST="$DIST_DIR"
makepkg -p "PKGBUILD.local" -f || exit 1

exit 0
