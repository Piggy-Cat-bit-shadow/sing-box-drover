<#
.SYNOPSIS
    Downloads the Windows x64 core from the custom sing-box fork and verifies it.

.DESCRIPTION
    Resolves the *latest* release of Piggy-Cat-bit-shadow/sing-box exactly once,
    then uses that frozen tag for every subsequent step so a single build can
    never mix two core versions.

    Steps (see project spec section 33):
      1. GET /repos/<owner>/<repo>/releases/latest   -> remember tag_name
      2. find the unique `jiejie-sing-box-windows-amd64-*.zip` asset in that tag
      3. download the zip and SHA256SUMS from the *same* tag
      4. compare SHA256; mismatch is a hard failure
      5. extract sing-box.exe
      6. copy it next to the GUI and write core.txt with tag + hash + real version

    No runtime core updater exists: this script is the only way the core moves.

.PARAMETER OutputDir
    Directory that receives sing-box.exe. Defaults to the repository root.

.PARAMETER Tag
    Pin a specific release tag instead of resolving `latest`.

.PARAMETER Force
    Re-download even when core.txt already records the same tag.

.EXAMPLE
    pwsh -File scripts/fetch-core.ps1 -OutputDir dist
#>

[CmdletBinding()]
param(
    [string]$OutputDir = '',
    [string]$Tag = '',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PowerShell 5.1 still defaults to TLS 1.0 on some machines, which GitHub rejects.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$CoreRepo = 'Piggy-Cat-bit-shadow/sing-box'
$AssetPattern = '^jiejie-sing-box-windows-amd64-.*\.zip$'
$SumsAssetName = 'SHA256SUMS'
$UserAgent = 'JieJieBox-build'

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-GitHubApi {
    param([string]$Uri)

    $headers = @{
        'User-Agent' = $UserAgent
        'Accept'     = 'application/vnd.github+json'
    }

    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)"
    }

    return Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get
}

function Get-AssetSha256 {
    param(
        [string]$SumsPath,
        [string]$AssetName
    )

    foreach ($line in Get-Content -LiteralPath $SumsPath) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '') { continue }

        $parts = $trimmed -split '\s+', 2
        if ($parts.Count -ne 2) { continue }

        $file = $parts[1].Trim()
        # GNU coreutils writes "*name" for binary mode.
        $file = $file.TrimStart('*')
        if ($file -eq $AssetName) {
            return $parts[0].Trim().ToLowerInvariant()
        }
    }

    return ''
}

# Reads the COFF machine field straight out of the PE header. The SHA256 only
# proves the bytes are the ones that were published; it says nothing about the
# architecture, so a wrong-architecture core must be rejected separately.
function Get-PeMachine {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40) {
        throw "File is too small to be a PE image: $Path"
    }
    if (($bytes[0] -ne 0x4D) -or ($bytes[1] -ne 0x5A)) {
        throw "File does not start with an MZ header: $Path"
    }

    $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
    if (($peOffset -le 0) -or ($peOffset + 6 -gt $bytes.Length)) {
        throw "File has an invalid PE header offset: $Path"
    }
    if (($bytes[$peOffset] -ne 0x50) -or ($bytes[$peOffset + 1] -ne 0x45)) {
        throw "File does not carry a PE signature: $Path"
    }

    return [System.BitConverter]::ToUInt16($bytes, $peOffset + 4)
}

# 0x8664 is IMAGE_FILE_MACHINE_AMD64.
function Assert-Amdfour {
    param(
        [string]$Path,
        [string]$What
    )

    $machine = Get-PeMachine -Path $Path
    if ($machine -ne 0x8664) {
        throw ("$What is not a Windows x86-64 (AMD64) binary: {0} (machine 0x{1:X4})." -f $Path, $machine)
    }
    Write-Host ("    {0} PE machine: 0x{1:X4} (AMD64)" -f $What, $machine) -ForegroundColor Green
}

# Downloads a release asset to a file, with retries.
#
# The public API asset endpoint is used rather than browser_download_url. Both
# resolve to the same bytes, but browser_download_url is served from
# github.com/releases/download and then redirects to the objects host; on networks
# where github.com is filtered that redirect fails part-way through the body
# ("unexpected EOF"). The API endpoint streams the asset directly and only needs
# api.github.com, which is the same host the release metadata already came from.
function Save-AssetFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string]$Description = 'asset'
    )

    $headers = @{
        'User-Agent' = $UserAgent
        'Accept'     = 'application/octet-stream'
    }
    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)"
    }

    $attempts = 3
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        if (Test-Path -LiteralPath $OutFile) {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        }

        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -Headers $headers -TimeoutSec 900
            if ((Test-Path -LiteralPath $OutFile) -and ((Get-Item -LiteralPath $OutFile).Length -gt 0)) {
                return
            }
            throw 'The downloaded file is empty.'
        }
        catch {
            if ($attempt -eq $attempts) {
                throw ("Failed to download $Description after $attempts attempts: $($_.Exception.Message)")
            }
            Write-Warning ("Download of $Description failed (attempt $attempt/$attempts): $($_.Exception.Message)")
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

try {
    if ($OutputDir -eq '') {
        $OutputDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    }
    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
    $corePath = Join-Path $OutputDir 'sing-box.exe'
    $stampPath = Join-Path $OutputDir 'core.txt'

    # --- 1. resolve the release exactly once -------------------------------
    if ($Tag -ne '') {
        Write-Step "Using pinned core release $Tag"
        $release = Invoke-GitHubApi "https://api.github.com/repos/$CoreRepo/releases/tags/$Tag"
    }
    else {
        Write-Step "Resolving latest core release of $CoreRepo"
        $release = Invoke-GitHubApi "https://api.github.com/repos/$CoreRepo/releases/latest"
    }

    $resolvedTag = $release.tag_name
    if (-not $resolvedTag) {
        throw "Release metadata for $CoreRepo did not contain a tag_name."
    }
    Write-Host "    tag: $resolvedTag"

    if ((-not $Force) -and (Test-Path -LiteralPath $stampPath) -and (Test-Path -LiteralPath $corePath)) {
        $existing = (Get-Content -LiteralPath $stampPath -Raw)
        if ($existing -match [regex]::Escape("tag=$resolvedTag")) {
            Write-Host "    already up to date; pass -Force to re-download." -ForegroundColor Green
            # return, not exit: package-release.ps1 dot-invokes this script, and an
            # exit here would tear down the whole packaging run.
            return
        }
    }

    # --- 2. locate the single Windows amd64 asset --------------------------
    $candidates = @($release.assets | Where-Object { $_.name -match $AssetPattern })
    if ($candidates.Count -eq 0) {
        $names = ($release.assets | ForEach-Object { $_.name }) -join ', '
        throw "No asset matching /$AssetPattern/ in $resolvedTag. Assets: $names"
    }
    if ($candidates.Count -gt 1) {
        $names = ($candidates | ForEach-Object { $_.name }) -join ', '
        throw "Ambiguous Windows amd64 asset in ${resolvedTag}: $names"
    }

    $asset = $candidates[0]
    $sumsAsset = @($release.assets | Where-Object { $_.name -eq $SumsAssetName })
    if ($sumsAsset.Count -ne 1) {
        throw "Release $resolvedTag does not contain exactly one $SumsAssetName."
    }

    Write-Host "    asset: $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)"

    $script:workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("jiejie-core-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:workDir -Force | Out-Null

    try {
        $zipPath = Join-Path $script:workDir $asset.name
        $sumsPath = Join-Path $script:workDir $SumsAssetName

        # --- 3. download zip + SHA256SUMS from the same tag -----------------
        # Both assets come from the frozen tag resolved in step 1, never from a
        # second `latest` lookup, so one build can never mix two core versions.
        Write-Step "Downloading core archive"
        Save-AssetFile -Uri $asset.url -OutFile $zipPath -Description $asset.name
        Save-AssetFile -Uri $sumsAsset[0].url -OutFile $sumsPath -Description $SumsAssetName

        # --- 4. verify -----------------------------------------------------
        Write-Step "Verifying SHA256"
        $expected = Get-AssetSha256 -SumsPath $sumsPath -AssetName $asset.name
        if ($expected -eq '') {
            throw "$SumsAssetName has no entry for $($asset.name)."
        }

        $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Host "    expected: $expected"
        Write-Host "    actual:   $actual"

        if ($actual -ne $expected) {
            throw "SHA256 mismatch for $($asset.name). Refusing to use this core."
        }
        Write-Host "    checksum OK" -ForegroundColor Green

        # --- 5. extract ----------------------------------------------------
        Write-Step "Extracting sing-box.exe"
        $extractDir = Join-Path $script:workDir 'extract'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

        $exe = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'sing-box.exe' |
            Select-Object -First 1
        if (-not $exe) {
            throw "sing-box.exe was not found inside $($asset.name)."
        }

        Copy-Item -LiteralPath $exe.FullName -Destination $corePath -Force

        # The archive hash is verified, but the architecture still has to be
        # checked explicitly - a hash match cannot detect a wrong-arch build.
        Assert-Amdfour -Path $corePath -What 'sing-box.exe'

        # --- 6. report the real version ------------------------------------
        # A core that cannot report its version is not usable, so this is a hard
        # failure rather than a warning: a "successful" fetch that produced an
        # unrunnable core would be worse than no core at all.
        Write-Step "Checking the core actually runs"
        $reportedVersion = ''
        $versionOutput = & $corePath version 2>&1
        $versionExit = $LASTEXITCODE
        if ($versionExit -ne 0) {
            throw "'sing-box.exe version' failed with exit code $versionExit. Output: $versionOutput"
        }
        if ($versionOutput) {
            $reportedVersion = ($versionOutput | Select-Object -First 1).ToString().Trim()
        }
        if ($reportedVersion -eq '') {
            throw "'sing-box.exe version' produced no output."
        }
        Write-Host "    version: $reportedVersion" -ForegroundColor Green

        $coreHash = (Get-FileHash -LiteralPath $corePath -Algorithm SHA256).Hash.ToLowerInvariant()

        $stamp = @(
            "repo=$CoreRepo",
            "tag=$resolvedTag",
            "asset=$($asset.name)",
            "asset_sha256=$expected",
            "sing-box.exe_sha256=$coreHash",
            "pe_machine=0x8664",
            "version=$reportedVersion"
        ) -join [Environment]::NewLine

        Set-Content -LiteralPath $stampPath -Value $stamp -Encoding UTF8

        Write-Host ''
        Write-Host "core installed: $corePath" -ForegroundColor Green
        Write-Host "  tag      : $resolvedTag"
        Write-Host "  asset    : $($asset.name)"
        Write-Host "  sha256   : $expected"
        Write-Host "  version  : $reportedVersion"
    }
    finally {
        if ($script:workDir -and (Test-Path -LiteralPath $script:workDir)) {
            Remove-Item -LiteralPath $script:workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
    # Rethrow instead of exit: this script must be safe to run as part of a larger
    # PowerShell session (package-release.ps1 does exactly that). The caller decides
    # how to report the failure, and a standalone caller still sees a terminating
    # error and a non-zero exit code.
    Write-Host ''
    Write-Host "fetch-core failed: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
