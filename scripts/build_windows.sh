#!/usr/bin/env bash
# Copyright (c) 2026 Maja Błaszczak
# SPDX-License-Identifier: GPL-3.0-or-later

# [
# shellcheck source=scripts/utils/build_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/utils/build_utils.sh" || exit 1

PROVISION_ARGS=()
CLEAN=false

PRINT_USAGE()
{
    echo "Usage: build_windows.sh [options]"
    echo " -r, --release : Accepted for compatibility"
    echo " -p, --provision : Force Vagrant VM provisioning"
    echo " -c, --clean : Destroy the existing Vagrant VM before building"
    echo " -h, --help : Show this help"
}

PREPARE_SCRIPT()
{
    while [ "$#" != 0 ]; do
        if [[ "$1" == "-r" ]] || [[ "$1" == "--release" ]]; then
            :
        elif [[ "$1" == "-p" ]] || [[ "$1" == "--provision" ]]; then
            PROVISION_ARGS=("--provision")
        elif [[ "$1" == "-c" ]] || [[ "$1" == "--clean" ]]; then
            CLEAN=true
        elif [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
            PRINT_USAGE
            exit 0
        else
            UNKNOWN_OPTION "$1"
        fi
        shift
    done
}

WAIT_FOR_WINRM()
{
    local ATTEMPT
    for (( ATTEMPT = 0; ATTEMPT < 30; ATTEMPT++ )); do
        if vagrant winrm -c "Write-Output 'Ready'" &> /dev/null; then
            return 0
        fi
        sleep 2
    done
    LOGE "Windows VM did not become ready"
    return 1
}

PULL_ARTIFACTS()
{
    local ATTEMPT GUEST_IP HOST_PORT
    HOST_PORT="$(vagrant port --guest 8080 2> /dev/null)" || HOST_PORT="58080"
    GUEST_IP="$(virsh --connect qemu:///system domifaddr Aira_default 2> /dev/null | \
        awk '$3 == "ipv4" && !found { split($4, addr, "/"); print addr[1]; found = 1 }')"

    for (( ATTEMPT = 0; ATTEMPT < 25; ATTEMPT++ )); do
        if [ "$GUEST_IP" ]; then
            nc -w 2 "$GUEST_IP" 8080 > "$ARTIFACTS_ZIP" 2> /dev/null || true
            [ -s "$ARTIFACTS_ZIP" ] && return 0
        fi
        nc -w 2 127.0.0.1 "$HOST_PORT" > "$ARTIFACTS_ZIP" 2> /dev/null || true
        [ -s "$ARTIFACTS_ZIP" ] && return 0
        sleep 1
    done
    return 1
}

TRANSFER_ARTIFACTS()
{
    local PULL_PID

    if command -v nc &> /dev/null; then
        PULL_ARTIFACTS &
        PULL_PID="$!"
        # shellcheck disable=SC2016
        vagrant winrm -c '
            netsh advfirewall firewall add rule name=ArtifactServer dir=in action=allow protocol=TCP localport=8080 | Out-Null
            $Listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, 8080)
            $Listener.Start()
            try {
                $Deadline = (Get-Date).AddSeconds(25)
                while (-not $Listener.Pending() -and (Get-Date) -lt $Deadline) {
                    Start-Sleep -Milliseconds 200
                }
                if ($Listener.Pending()) {
                    $Client = $Listener.AcceptTcpClient()
                    $File = [System.IO.File]::OpenRead("C:\vagrant\artifacts.zip")
                    try {
                        $File.CopyTo($Client.GetStream())
                    } finally {
                        $File.Dispose()
                        $Client.Dispose()
                    }
                }
            } finally {
                $Listener.Stop()
                netsh advfirewall firewall delete rule name=ArtifactServer | Out-Null
            }
        ' > /dev/null 2>&1 || true
        wait "$PULL_PID" || true
    fi

    if ! unzip -tq "$ARTIFACTS_ZIP" &> /dev/null; then
        LOGW "Transferring artifacts over WinRM"
        vagrant winrm -c '[Convert]::ToBase64String([System.IO.File]::ReadAllBytes("C:\vagrant\artifacts.zip"), [System.Base64FormattingOptions]::InsertLineBreaks)' | \
            tr -d '\r\n ' | base64 -d > "$ARTIFACTS_ZIP" || return 1
    fi

    local ZIP_NAME="Aira-$GIT_HASH-windows-x64.zip"
    if ! unzip -tq "$ARTIFACTS_ZIP" "$ZIP_NAME" &> /dev/null; then
        LOGE "Windows ZIP missing from VM artifacts"
        return 1
    fi
    unzip -oq "$ARTIFACTS_ZIP" -d "$DIST_DIR" || return 1
}

BUILD_IN_VM()
{
    if ! command -v vagrant &> /dev/null; then
        LOGE "Vagrant with the libvirt provider is required"
        return 1
    fi
    export VAGRANT_DEFAULT_PROVIDER="libvirt"

    if $CLEAN; then
        LOG "Destroying existing Vagrant VM"
        vagrant destroy -f || return 1
    fi

    LOG "Starting Windows VM"
    vagrant up --provider=libvirt "${PROVISION_ARGS[@]}" || return 1
    VM_STARTED=true

    LOG "Waiting for WinRM"
    WAIT_FOR_WINRM || return 1

    LOG "Archiving Flutter sources"
    zip -rq "$WORK_DIR/source.zip" ".metadata" "pubspec.yaml" "pubspec.lock" "analysis_options.yaml" \
        "assets" "lib" "windows" "packaging/windows" "scripts/build_windows.ps1" \
        -x 'windows/flutter/ephemeral/*' '*.pyc' || return 1
    LOG "Uploading Flutter sources"
    vagrant upload "$WORK_DIR/source.zip" 'C:\aira_src.zip' || return 1

    LOG "Building Windows packages in the VM"
    # shellcheck disable=SC2016
    vagrant winrm -c '
        $ErrorActionPreference = "Stop"
        if (Test-Path "C:\vagrant") {
            Remove-Item "C:\vagrant" -Recurse -Force
        }
        Expand-Archive -Path "C:\aira_src.zip" -DestinationPath "C:\vagrant"
        Remove-Item "C:\aira_src.zip" -Force
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path", "User")
        $env:DART_VM_OPTIONS = "--old_gen_heap_size=2048"
        Set-Location "C:\vagrant"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows.ps1 -GitHash '"$GIT_HASH"'
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Compress-Archive -Path "dist\*" -DestinationPath "artifacts.zip"
    ' || return 1

    LOG "Retrieving Windows packages"
    TRANSFER_ARTIFACTS || return 1

    LOG "Halting Windows VM"
    vagrant halt || return 1
    VM_STARTED=false
}

# shellcheck disable=SC2329
CLEANUP()
{
    if $VM_STARTED; then
        vagrant halt || LOGW "Could not halt the Windows VM"
    fi
    rm -rf -- "$WORK_DIR"
}
# ]

set -o pipefail
PREPARE_SCRIPT "$@"
PREPARE_BUILD

if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "scripts/build_windows.ps1" -GitHash "$GIT_HASH" || exit 1
else
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aira-windows.XXXXXXXX")" || exit 1
    ARTIFACTS_ZIP="$WORK_DIR/artifacts.zip"
    VM_STARTED=false
    trap CLEANUP EXIT
    BUILD_IN_VM || exit 1
fi

exit 0
