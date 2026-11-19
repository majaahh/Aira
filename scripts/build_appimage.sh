#!/usr/bin/env bash
# Copyright (c) 2026 Maja Błaszczak
# SPDX-License-Identifier: GPL-3.0-or-later

# [
# shellcheck source=scripts/utils/build_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/utils/build_utils.sh" || exit 1

PACKAGE_ONLY=false

PRINT_USAGE()
{
    echo "Usage: build_appimage.sh [options]"
    echo " -r, --release : Accepted for compatibility"
    echo "     --package-only : Package an existing Flutter Linux bundle"
    echo " -h, --help : Show this help"
}

PREPARE_SCRIPT()
{
    while [ "$#" != 0 ]; do
        if [[ "$1" == "-r" ]] || [[ "$1" == "--release" ]]; then
            :
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

GET_APPIMAGETOOL()
{
    APPIMAGETOOL="$(command -v appimagetool)" && return 0

    APPIMAGETOOL="$WORK_DIR/appimagetool"
    LOG "Downloading appimagetool"
    curl -fsSL -o "$APPIMAGETOOL" \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage" || return 1
    chmod +x "$APPIMAGETOOL"
}
# ]

PREPARE_SCRIPT "$@"
PREPARE_BUILD

if ! $PACKAGE_ONLY; then
    BUILD_LINUX_BUNDLE || exit 1
fi

BUNDLE_DIR="build/linux/x64/release/bundle"
if [ ! -f "$BUNDLE_DIR/aira" ]; then
    LOGE "Flutter Linux bundle missing: $BUNDLE_DIR"
    exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aira-appimage.XXXXXXXX")" || exit 1
trap 'rm -rf -- "$WORK_DIR"' EXIT
APP_DIR="$WORK_DIR/AppDir"
OUTPUT_NAME="Aira-$GIT_HASH-x86_64.AppImage"

LOG "Preparing AppDir"
mkdir -p "$APP_DIR/usr/bin" "$APP_DIR/usr/share/icons" || exit 1
cp -R "$BUNDLE_DIR/." "$APP_DIR/usr/bin/" || exit 1
cp "packaging/linux/io.majaahh.aira.desktop" "packaging/linux/io.majaahh.aira.png" "$APP_DIR/" || exit 1
cp "packaging/linux/io.majaahh.aira.png" "$APP_DIR/.DirIcon" || exit 1
cp -R "packaging/linux/icons/hicolor" "$APP_DIR/usr/share/icons/" || exit 1

# shellcheck disable=SC2016
{
    echo '#!/usr/bin/env bash'
    echo '# Copyright (c) 2026 Maja Błaszczak'
    echo '# SPDX-License-Identifier: GPL-3.0-or-later'
    echo 'APP_DIR="$(dirname "$(readlink -f "$0")")"'
    echo 'exec "$APP_DIR/usr/bin/aira" "$@"'
} > "$APP_DIR/AppRun" || exit 1
chmod +x "$APP_DIR/AppRun" || exit 1

GET_APPIMAGETOOL || exit 1
LOG "Creating AppImage in dist/"
ARCH=x86_64 "$APPIMAGETOOL" "$APP_DIR" "$DIST_DIR/$OUTPUT_NAME" || exit 1

exit 0
