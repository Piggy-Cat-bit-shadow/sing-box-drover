<#
.SYNOPSIS
    Builds the JieJieBox GUI for Windows x64 and produces the complete unsigned
    test package.

.DESCRIPTION
    Steps:
      1. locate a real RAD Studio installation and build the project (Release, Win64)
      2. fetch + SHA256-verify the custom sing-box core (scripts/fetch-core.ps1)
      3. assemble dist\<PackageName>-Windows-amd64-test-<shortSHA>\
      4. write BUILDINFO.txt and SHA256SUMS.txt
      5. zip it and then re-extract the archive into a clean directory and verify
         every recorded hash

    Design notes:
      * The compiler is invoked through the installation's own rsvars.bat inside a
        single cmd.exe session. System-level MSBuild alone is not a Delphi
        toolchain: rsvars.bat must be applied first or the Delphi targets are not
        found.
      * PowerShell 5.1+ only. Nothing here needs PowerShell 7, and no external
        host is spawned for the core fetch.
      * There is deliberately no "opener.exe" step and no config-only zip. Patching
        a compiled EXE by appending a resource does not produce a working archive
        opener, and a config-only zip would hand the user a package without a core.

.PARAMETER Config
    Build configuration. Default: Release.

.PARAMETER Platform
    Target platform. Default: Win64.

.PARAMETER Version
    Version string for the output folder and zip name. Default: read from the
    VERSIONINFO of the built JieJieBox.exe, which in turn comes from app.res.

.PARAMETER SkipBuild
    Reuse an already built JieJieBox.exe. Only accepted when the build stamp proves
    the EXE came from the current git commit and the same build session.

.PARAMETER SkipCore
    Reuse an already fetched sing-box.exe instead of contacting GitHub.

.PARAMETER CoreTag
    Pin a specific core release tag (passed through to fetch-core.ps1).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package-release.ps1
#>

[CmdletBinding()]
param(
    [string]$Config = 'Release',
    [string]$Platform = 'Win64',
    [string]$Version = '',
    [switch]$SkipBuild,
    [switch]$SkipCore,
    [string]$CoreTag = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$PackageName = 'JieJieBox'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ProjectFile = Join-Path $Root 'sing_box_drover.dproj'
$BuildStampName = '.build-stamp.txt'

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# git / build identity
# ---------------------------------------------------------------------------

# Reads the commit SHA without depending on git being installed: the loose ref is
# enough, and a packaged checkout has .git/HEAD either way.
function Get-GitHeadSha {
    param([string]$RepoRoot)

    $gitDir = Join-Path $RepoRoot '.git'
    if (-not (Test-Path -LiteralPath $gitDir)) {
        return ''
    }

    $headPath = Join-Path $gitDir 'HEAD'
    if (-not (Test-Path -LiteralPath $headPath)) {
        return ''
    }

    $head = (Get-Content -LiteralPath $headPath -Raw).Trim()
    if ($head -match '^[0-9a-fA-F]{40}$') {
        return $head.ToLowerInvariant()
    }

    if ($head -match '^ref:\s*(.+)$') {
        $refPath = Join-Path $gitDir ($Matches[1].Trim() -replace '/', '\')
        if (Test-Path -LiteralPath $refPath) {
            $sha = (Get-Content -LiteralPath $refPath -Raw).Trim()
            if ($sha -match '^[0-9a-fA-F]{40}$') {
                return $sha.ToLowerInvariant()
            }
        }

        # Packed refs.
        $packedPath = Join-Path $gitDir 'packed-refs'
        if (Test-Path -LiteralPath $packedPath) {
            $refName = $Matches[1].Trim()
            foreach ($line in Get-Content -LiteralPath $packedPath) {
                if ($line.StartsWith('#') -or $line.Trim() -eq '') { continue }
                $parts = $line -split '\s+', 2
                if (($parts.Count -eq 2) -and ($parts[1].Trim() -eq $refName)) {
                    return $parts[0].Trim().ToLowerInvariant()
                }
            }
        }
    }

    return ''
}

# ---------------------------------------------------------------------------
# PE inspection
# ---------------------------------------------------------------------------

function Get-PeMachine {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40) { throw "File is too small to be a PE image: $Path" }
    if (($bytes[0] -ne 0x4D) -or ($bytes[1] -ne 0x5A)) { throw "Missing MZ header: $Path" }

    $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
    if (($peOffset -le 0) -or ($peOffset + 6 -gt $bytes.Length)) {
        throw "Invalid PE header offset: $Path"
    }
    if (($bytes[$peOffset] -ne 0x50) -or ($bytes[$peOffset + 1] -ne 0x45)) {
        throw "Missing PE signature: $Path"
    }

    return [System.BitConverter]::ToUInt16($bytes, $peOffset + 4)
}

function Assert-Amdfour {
    param([string]$Path, [string]$What)

    $machine = Get-PeMachine -Path $Path
    if ($machine -ne 0x8664) {
        throw ("{0} is not a Windows x86-64 (AMD64) binary: {1} (machine 0x{2:X4})." -f $What, $Path, $machine)
    }
    Write-Host ("    {0} PE machine: 0x{1:X4} (AMD64)" -f $What, $machine) -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Delphi discovery and build
# ---------------------------------------------------------------------------

function Find-Delphi {
    <#
        Returns the directory that contains rsvars.bat, or ''.

        The previous version probed a hardcoded short list and then did
        `Join-Path (Split-Path $BdsBin -Parent) 'rsvars.bat'`, which walks *up* one
        level from ...\Studio\37.0\bin and therefore never finds the file that
        lives inside that very bin directory. Here rsvars.bat is looked for in the
        candidate directory itself, and every currently installed version is
        enumerated from the registry rather than assumed.
    #>
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($env:BDS) { $candidates.Add((Join-Path $env:BDS 'bin')) }

    foreach ($hive in @('HKLM:\SOFTWARE\Embarcadero\BDS',
            'HKLM:\SOFTWARE\WOW6432Node\Embarcadero\BDS',
            'HKCU:\SOFTWARE\Embarcadero\BDS')) {
        if (-not (Test-Path $hive)) { continue }
        foreach ($key in Get-ChildItem -Path $hive -ErrorAction SilentlyContinue) {
            $root = (Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue).RootDir
            if ($root) { $candidates.Add((Join-Path $root 'bin')) }
        }
    }

    # Only as a last resort: scan the standard install roots for version folders.
    foreach ($programFiles in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $programFiles) { continue }
        $studioRoot = Join-Path $programFiles 'Embarcadero\Studio'
        if (-not (Test-Path -LiteralPath $studioRoot)) { continue }
        foreach ($dir in Get-ChildItem -LiteralPath $studioRoot -Directory -ErrorAction SilentlyContinue) {
            $candidates.Add((Join-Path $dir.FullName 'bin'))
        }
    }

    foreach ($dir in $candidates) {
        if (-not $dir) { continue }
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        if (Test-Path -LiteralPath (Join-Path $dir 'rsvars.bat')) {
            return (Resolve-Path -LiteralPath $dir).Path
        }
    }

    return ''
}

function Find-MSBuild {
    # rsvars.bat puts %FrameworkDir% on the PATH, so msbuild.exe is normally
    # resolved from there. Fall back to the known .NET Framework locations so a
    # machine without a system-wide msbuild still works.
    foreach ($path in @(
            (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe'),
            (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\MSBuild.exe'))) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return 'msbuild.exe'
}

function Invoke-DelphiBuild {
    param([string]$BdsBin)

    $rsvars = Join-Path $BdsBin 'rsvars.bat'
    if (-not (Test-Path -LiteralPath $rsvars)) {
        throw "rsvars.bat not found in $BdsBin."
    }
    Write-Host "    rsvars: $rsvars"

    $msbuild = Find-MSBuild
    $logPath = Join-Path $Root "build-$Platform-$Config.log"

    # rsvars.bat must run in the *same* cmd.exe session as MSBuild: it only sets
    # environment variables for its own process tree.
    $command = 'call "{0}" >nul && "{1}" "{2}" /t:Rebuild /p:Config={3} /p:Platform={4} /v:normal /nologo' -f `
        $rsvars, $msbuild, $ProjectFile, $Config, $Platform

    Write-Host "    msbuild: $msbuild"
    Write-Host "    log    : $logPath"

    $output = & cmd.exe /c $command 2>&1
    $exitCode = $LASTEXITCODE
    $output | Set-Content -LiteralPath $logPath -Encoding UTF8

    if ($exitCode -ne 0) {
        $tail = ($output | Select-Object -Last 30) -join [Environment]::NewLine
        throw ("Delphi $Platform/$Config build failed with exit code {0}. See {1}{2}{3}" -f `
                $exitCode, $logPath, [Environment]::NewLine, $tail)
    }

    Write-Host "    build exit code: 0" -ForegroundColor Green
}

# Reads the real GUI version out of the compiled binary's VERSIONINFO, which is
# stamped by app.res. The core version must never be mistaken for it.
function Get-GuiFileVersion {
    param([string]$ExePath)

    try {
        $info = (Get-Item -LiteralPath $ExePath).VersionInfo
        if ($info -and $info.FileVersion) {
            return $info.FileVersion.Trim()
        }
    }
    catch {
        # VersionInfo is best-effort; the caller has a fallback.
    }
    return ''
}

# ---------------------------------------------------------------------------

try {
    Write-Step 'JieJieBox Windows x64 test package'
    Write-Host "    root: $Root"

    if ($Platform -ne 'Win64') {
        throw "Only the Win64 platform is supported by this project; got '$Platform'."
    }

    $headSha = Get-GitHeadSha -RepoRoot $Root
    if ($headSha -eq '') { $headSha = 'nogit' }
    $shortSha = $headSha.Substring(0, [Math]::Min(7, $headSha.Length))
    Write-Host "    GUI commit: $headSha"

    $builtExe = Join-Path $Root "$Platform\$Config\$PackageName.exe"
    $stampPath = Join-Path $Root $BuildStampName

    # --- 1. build ----------------------------------------------------------
    if (-not $SkipBuild) {
        $bdsBin = Find-Delphi
        if ($bdsBin -eq '') {
            throw ('No usable RAD Studio installation detected (no rsvars.bat found). ' +
                'Install a Delphi/RAD Studio edition that includes the Windows 64-bit target, ' +
                'or pass -SkipBuild with an EXE that was already built from this commit.')
        }
        Write-Host "    Delphi bin: $bdsBin"
        Write-Step "Building $PackageName ($Config, $Platform)"

        # Rebuild from scratch so a stale EXE can never be mistaken for this run's output.
        if (Test-Path -LiteralPath $builtExe) {
            Remove-Item -LiteralPath $builtExe -Force
        }

        Invoke-DelphiBuild -BdsBin $bdsBin

        @(
            "gui_commit=$headSha"
            "platform=$Platform"
            "config=$Config"
            "built_at=$((Get-Date).ToString('o'))"
        ) -join [Environment]::NewLine | Set-Content -LiteralPath $stampPath -Encoding ASCII
    }
    else {
        # -SkipBuild is only allowed when the stamp proves provenance: same commit
        # and a recorded build. Otherwise a stale EXE could masquerade as this build.
        if (-not (Test-Path -LiteralPath $builtExe)) {
            throw "-SkipBuild was given but $builtExe does not exist."
        }
        if (-not (Test-Path -LiteralPath $stampPath)) {
            throw ("-SkipBuild was given but $BuildStampName is missing, so the EXE cannot be " +
                'proven to come from this commit. Run a full build first.')
        }

        $stampText = Get-Content -LiteralPath $stampPath -Raw
        $stampCommit = ''
        foreach ($line in ($stampText -split "`r?`n")) {
            $kv = $line -split '=', 2
            if (($kv.Count -eq 2) -and ($kv[0].Trim() -eq 'gui_commit')) { $stampCommit = $kv[1].Trim() }
        }

        if ($stampCommit -ne $headSha) {
            throw ("-SkipBuild refused: the EXE was built from commit '$stampCommit' but HEAD is " +
                "'$headSha'. Rebuild instead of packaging a stale binary.")
        }
        Write-Host "    reusing $builtExe (stamp matches $shortSha)" -ForegroundColor Yellow
    }

    if (-not (Test-Path -LiteralPath $builtExe)) {
        throw "GUI executable not found: $builtExe"
    }

    # Provenance of the artefact we are about to ship.
    $guiInfo = Get-Item -LiteralPath $builtExe
    $guiSha = (Get-FileHash -LiteralPath $builtExe -Algorithm SHA256).Hash.ToLowerInvariant()
    $guiVersion = Get-GuiFileVersion -ExePath $builtExe
    if ($guiVersion -eq '') { $guiVersion = '0.0.0.0' }

    Write-Host "    exe: $builtExe"
    Write-Host "    exe modified: $($guiInfo.LastWriteTime.ToString('o'))"
    Write-Host "    exe version : $guiVersion"
    Write-Host "    exe sha256  : $guiSha"
    Assert-Amdfour -Path $builtExe -What "$PackageName.exe"

    if ($Version -eq '') { $Version = 'v' + $guiVersion }

    # --- 2. core -----------------------------------------------------------
    if (-not $SkipCore) {
        $fetchScript = Join-Path $PSScriptRoot 'fetch-core.ps1'
        if (-not (Test-Path -LiteralPath $fetchScript)) {
            throw "Core fetch script not found: $fetchScript"
        }

        Write-Step 'Fetching and verifying the core'
        $fetchArgs = @{ OutputDir = $Root }
        if ($CoreTag -ne '') { $fetchArgs['Tag'] = $CoreTag }

        # Invoked with & (not dot-sourced) so fetch-core.ps1 keeps its own scope and
        # a failure surfaces here as a terminating error. PowerShell 5.1 is enough:
        # this no longer spawns pwsh.exe.
        & $fetchScript @fetchArgs
    }

    $coreExe = Join-Path $Root 'sing-box.exe'
    if (-not (Test-Path -LiteralPath $coreExe)) {
        throw "Core executable not found: $coreExe"
    }
    Assert-Amdfour -Path $coreExe -What 'sing-box.exe'

    # core.txt is written by fetch-core.ps1.
    $coreStamp = @{}
    $coreStampPath = Join-Path $Root 'core.txt'
    if (Test-Path -LiteralPath $coreStampPath) {
        foreach ($line in Get-Content -LiteralPath $coreStampPath) {
            $kv = $line -split '=', 2
            if ($kv.Count -eq 2) { $coreStamp[$kv[0].Trim()] = $kv[1].Trim() }
        }
    }
    if (-not $coreStamp.ContainsKey('tag')) {
        throw 'core.txt is missing or has no tag; the bundled core cannot be identified.'
    }

    $coreTag = $coreStamp['tag']
    $coreVersion = ''
    if ($coreStamp.ContainsKey('version')) { $coreVersion = $coreStamp['version'] }
    $coreAsset = ''
    if ($coreStamp.ContainsKey('asset')) { $coreAsset = $coreStamp['asset'] }
    $coreHash = (Get-FileHash -LiteralPath $coreExe -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($coreStamp.ContainsKey('sing-box.exe_sha256') -and
        ($coreStamp['sing-box.exe_sha256'] -ne $coreHash)) {
        throw ("sing-box.exe does not match the hash recorded in core.txt " +
            "($($coreStamp['sing-box.exe_sha256']) vs $coreHash). Refusing to package.")
    }

    # --- 3. assemble -------------------------------------------------------
    $testDirName = "$PackageName-Windows-amd64-test-$shortSha"
    $distRoot = Join-Path $Root 'dist'
    $stageDir = Join-Path $distRoot $testDirName
    if (Test-Path -LiteralPath $stageDir) {
        Remove-Item -LiteralPath $stageDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    Write-Step "Staging $stageDir"
    Copy-Item -LiteralPath $builtExe -Destination (Join-Path $stageDir "$PackageName.exe") -Force
    Copy-Item -LiteralPath $coreExe -Destination (Join-Path $stageDir 'sing-box.exe') -Force
    Copy-Item -LiteralPath (Join-Path $Root 'config.json') -Destination $stageDir -Force
    Copy-Item -LiteralPath (Join-Path $Root "$PackageName.ini") -Destination $stageDir -Force
    Copy-Item -LiteralPath (Join-Path $Root 'README.md') -Destination $stageDir -Force

    New-Item -ItemType Directory -Path (Join-Path $stageDir 'profiles') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $stageDir 'profiles\README.txt') -Encoding ASCII -Value @'
Remote subscription profiles are stored in this directory as .bpf files.
This directory ships empty: add subscriptions from the tray menu.
'@

    $builtAt = (Get-Date).ToString('o')
    $buildInfo = @(
        "$PackageName Windows amd64 test package (unsigned)"
        "package_name   = $testDirName"
        "gui_commit     = $headSha"
        "gui_sha256     = $guiSha"
        "gui_version    = $guiVersion"
        "delphi_bin     = $(if ($SkipBuild) { '(reused build)' } else { $bdsBin })"
        "build_config   = $Config"
        "build_platform = $Platform"
        "built_at       = $builtAt"
        "host_os        = $([Environment]::OSVersion.VersionString)"
        "core_repo      = $($coreStamp['repo'])"
        "core_tag       = $coreTag"
        "core_asset     = $coreAsset"
        "core_asset_sha256 = $($coreStamp['asset_sha256'])"
        "core_sha256    = $coreHash"
        "core_version   = $coreVersion"
        "pe_machine     = 0x8664 (AMD64)"
        "signed         = no"
        "run_verified   = $(if ($SkipBuild) { 'not run by this script' } else { 'build only; see test report' })"
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath (Join-Path $stageDir 'BUILDINFO.txt') -Value $buildInfo -Encoding UTF8

    # Hashes are computed over the staged files, and SHA256SUMS.txt itself is then
    # excluded from the manifest (it cannot contain its own hash).
    $sumLines = New-Object System.Collections.Generic.List[string]
    foreach ($file in (Get-ChildItem -LiteralPath $stageDir -File | Sort-Object Name)) {
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $sumLines.Add("$hash *$($file.Name)")
    }
    Set-Content -LiteralPath (Join-Path $stageDir 'SHA256SUMS.txt') -Value ($sumLines -join [Environment]::NewLine) -Encoding ASCII

    # --- 4. zip ------------------------------------------------------------
    Write-Step 'Creating the archive'
    $zipPath = Join-Path $distRoot "$testDirName.zip"
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $zipPath -CompressionLevel Optimal

    # --- 5. verify the archive by re-extracting it -------------------------
    Write-Step 'Verifying the archive contents'
    $verifyDir = Join-Path ([System.IO.Path]::GetTempPath()) ("jiejie-verify-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $verifyDir -Force | Out-Null

    try {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $verifyDir -Force

        $extracted = Get-ChildItem -LiteralPath $verifyDir -Recurse -File
        if ($extracted.Count -eq 0) {
            throw 'The archive extracted to no files.'
        }

        # The archive root must be flat: every file sits directly in $verifyDir, and
        # the only subdirectory allowed is profiles.
        foreach ($item in (Get-ChildItem -LiteralPath $verifyDir)) {
            if ($item.PSIsContainer -and ($item.Name -ne 'profiles')) {
                throw "Unexpected directory inside the archive: $($item.Name)"
            }
            if (-not $item.PSIsContainer -and
                ($item.Name -notin @("$PackageName.exe", 'sing-box.exe', "$PackageName.ini",
                        'README.md', 'BUILDINFO.txt', 'SHA256SUMS.txt'))) {
                throw "Unexpected file inside the archive: $($item.Name)"
            }
        }

        foreach ($required in @("$PackageName.exe", 'sing-box.exe', "$PackageName.ini",
                'README.md', 'BUILDINFO.txt', 'SHA256SUMS.txt')) {
            if (-not (Test-Path -LiteralPath (Join-Path $verifyDir $required))) {
                throw "Required file missing from the archive: $required"
            }
        }

        # Re-verify every recorded hash against the extracted bytes.
        $sumsFromArchive = Get-Content -LiteralPath (Join-Path $verifyDir 'SHA256SUMS.txt')
        foreach ($line in $sumsFromArchive) {
            $trimmed = $line.Trim()
            if ($trimmed -eq '') { continue }
            $parts = $trimmed -split '\s+', 2
            if ($parts.Count -ne 2) { throw "Malformed line in SHA256SUMS.txt: $trimmed" }

            $expectedHash = $parts[0].Trim().ToLowerInvariant()
            $fileName = $parts[1].Trim().TrimStart('*')
            $filePath = Join-Path $verifyDir $fileName
            if (-not (Test-Path -LiteralPath $filePath)) {
                throw "SHA256SUMS.txt lists a file that is not in the archive: $fileName"
            }

            $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualHash -ne $expectedHash) {
                throw "Hash mismatch after extraction for $fileName ($expectedHash vs $actualHash)."
            }
        }

        Assert-Amdfour -Path (Join-Path $verifyDir "$PackageName.exe") -What 'archived JieJieBox.exe'
        Assert-Amdfour -Path (Join-Path $verifyDir 'sing-box.exe') -What 'archived sing-box.exe'

        # The archive must never carry repository or secret material.
        foreach ($forbidden in @('.git', '.env', 'core.txt', 'build-Win64-Release.log')) {
            if (Get-ChildItem -LiteralPath $verifyDir -Recurse -Force -Filter $forbidden -ErrorAction SilentlyContinue) {
                throw "Forbidden entry found inside the archive: $forbidden"
            }
        }

        $zipSha = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()

        Write-Host ''
        Write-Host 'package ready' -ForegroundColor Green
        Write-Host "  zip        : $zipPath"
        Write-Host "  zip sha256 : $zipSha"
        Write-Host "  files      : $(($extracted | ForEach-Object { $_.Name }) -join ', ')"
        Write-Host "  gui commit : $headSha"
        Write-Host "  core       : $coreTag ($coreHash)"
        Write-Host "  core ver   : $coreVersion"
    }
    finally {
        if (Test-Path -LiteralPath $verifyDir) {
            Remove-Item -LiteralPath $verifyDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
    Write-Host ''
    Write-Host "package-release failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
