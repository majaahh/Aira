# Copyright (c) 2026 Maja Błaszczak
# SPDX-License-Identifier: GPL-3.0-or-later

param (
    [switch]$Release,
    [switch]$Help,
    [ValidatePattern('^([0-9a-f]+|unknown)$')]
    [string]$GitHash
)

function Print-Usage
{
    Write-Output 'Usage: .\scripts\build_windows.ps1 [-Release] [-GitHash <hash>]'
    Write-Output ' -Release : Accepted for compatibility'
    Write-Output ' -GitHash : Set the commit hash when building outside a Git checkout'
    Write-Output ' -Help    : Show this help'
}

if ($Help) {
    Print-Usage
    exit 0
}

$ErrorActionPreference = 'Stop'
$RootDir = Split-Path -Parent $PSScriptRoot
Push-Location $RootDir
try {
    if (-not $GitHash) {
        $GitHash = git rev-parse --short HEAD
        if ($LASTEXITCODE -ne 0 -or -not $GitHash) {
            $GitHash = 'unknown'
        }
    }

    $DistDir = Join-Path $RootDir 'dist'
    $BuildDir = Join-Path $RootDir 'build\windows\x64\runner\Release'
    $ZipPath = Join-Path $DistDir "Aira-$GitHash-windows-x64.zip"
    $SetupBase = "Aira-$GitHash-windows-x64-setup"

    Write-Host 'Building Flutter Windows bundle'
    flutter build windows --release "--dart-define=GIT_HASH=$GitHash"
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter build failed ($LASTEXITCODE)"
    }
    if (-not (Test-Path (Join-Path $BuildDir 'aira.exe') -PathType Leaf)) {
        throw "Flutter build output missing from $BuildDir"
    }

    New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
    Write-Host 'Creating Windows ZIP in dist/'
    if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
        & tar.exe -a -c -f $ZipPath -C $BuildDir .
        if ($LASTEXITCODE -ne 0) {
            throw "Creating the Windows ZIP failed ($LASTEXITCODE)"
        }
    } else {
        Compress-Archive -Path "$BuildDir\*" -DestinationPath $ZipPath -Force
    }

    $DefaultIsccPath = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    $IsccPath = $DefaultIsccPath
    if (-not (Test-Path $IsccPath)) {
        $IsccPath = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
    }
    if (-not $IsccPath -and (Get-Command choco -ErrorAction SilentlyContinue)) {
        choco install -y innosetup --no-progress
        if (Test-Path $DefaultIsccPath) {
            $IsccPath = $DefaultIsccPath
        }
    }
    if (-not $IsccPath) {
        Write-Warning 'Inno Setup unavailable. Only the standalone ZIP was created.'
        exit 0
    }

    $Version = '0.1.0'
    if ((Get-Content -Raw pubspec.yaml) -match '(?m)^version:\s*([^\s+]+)') {
        $Version = $Matches[1]
    }

    $IsccArgs = @(
        "/DAppVersion=$Version", '/DAppArch=x64', "/DProjectRoot=$RootDir",
        "/DBuildDir=$BuildDir", "/DOutputDir=$DistDir", "/DOutputBaseFilename=$SetupBase",
        "$RootDir\packaging\windows\inno_setup.iss"
    )
    Write-Host 'Creating Windows installer in dist/'
    & $IsccPath @IsccArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup failed ($LASTEXITCODE)"
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
} finally {
    Pop-Location
}
