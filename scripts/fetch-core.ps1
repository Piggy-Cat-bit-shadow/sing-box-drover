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
            exit 0
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
        throw "Ambiguous Windows amd64 asset in $resolvedTag: $names"
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
        Write-Step "Downloading core archive"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing -Headers @{ 'User-Agent' = $UserAgent }
        Invoke-WebRequest -Uri $sumsAsset[0].browser_download_url -OutFile $sumsPath -UseBasicParsing -Headers @{ 'User-Agent' = $UserAgent }

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

        # --- 6. report the real version ------------------------------------
        $reportedVersion = ''
        try {
            $firstLine = (& $corePath version 2>&1 | Select-Object -First 1)
            if ($firstLine) {
                $reportedVersion = $firstLine.ToString().Trim()
            }
        }
        catch {
            Write-Warning "Could not run '$corePath version': $($_.Exception.Message)"
        }

        $coreHash = (Get-FileHash -LiteralPath $corePath -Algorithm SHA256).Hash.ToLowerInvariant()

        $stamp = @(
            "repo=$CoreRepo",
            "tag=$resolvedTag",
            "asset=$($asset.name)",
            "asset_sha256=$expected",
            "sing-box.exe_sha256=$coreHash",
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

    exit 0
}
catch {
    Write-Host ''
    Write-Host "fetch-core failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
