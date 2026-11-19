#!/usr/bin/env bash
# Copyright (c) 2026 Maja Błaszczak
# SPDX-License-Identifier: GPL-3.0-or-later

# [
# shellcheck source=scripts/utils/build_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/utils/build_utils.sh" || exit 1

BUILD_BUNDLE=false
BUILD_UNIVERSAL=false
BUILD_MODE="debug"

PRINT_USAGE()
{
    echo "Usage: build_android.sh [options]"
    echo " -r, --release : Build release APKs"
    echo " -b, --bundle : Build a release app bundle"
    echo " -u, --universal : Build one APK for all ABIs"
    echo " -h, --help : Show this help"
    echo " By default, builds one debug APK per ABI."
}

PREPARE_SCRIPT()
{
    while [ "$#" != 0 ]; do
        if [[ "$1" == "-r" ]] || [[ "$1" == "--release" ]]; then
            BUILD_MODE="release"
        elif [[ "$1" == "-b" ]] || [[ "$1" == "--bundle" ]]; then
            BUILD_BUNDLE=true
            BUILD_MODE="release"
        elif [[ "$1" == "-u" ]] || [[ "$1" == "--universal" ]]; then
            BUILD_UNIVERSAL=true
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

BUILD_ARGS=("--$BUILD_MODE" "--dart-define=GIT_HASH=$GIT_HASH")
APK_SUFFIX=""
if [[ "$BUILD_MODE" == "release" ]]; then
    BUILD_ARGS+=("--obfuscate" "--split-debug-info=build/symbols")
else
    APK_SUFFIX="-debug"
fi

APK_DIR="build/app/outputs/flutter-apk"
LOG "Building Android $BUILD_MODE"

if $BUILD_BUNDLE; then
    flutter build appbundle "${BUILD_ARGS[@]}" || exit 1
    COPY_ARTIFACT "build/app/outputs/bundle/release/app-release.aab" "Aira-$GIT_HASH.aab" || exit 1
elif $BUILD_UNIVERSAL; then
    flutter build apk "${BUILD_ARGS[@]}" || exit 1
    COPY_ARTIFACT "$APK_DIR/app-$BUILD_MODE.apk" "Aira-$GIT_HASH-universal$APK_SUFFIX.apk" || exit 1
else
    flutter build apk --split-per-abi "${BUILD_ARGS[@]}" || exit 1
    COPY_ARTIFACT "$APK_DIR/app-arm64-v8a-$BUILD_MODE.apk" "Aira-$GIT_HASH-arm64-v8a$APK_SUFFIX.apk" || exit 1
fi

exit 0
