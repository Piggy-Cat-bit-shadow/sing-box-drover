[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ZipPath
)

<#
    JieJieBox Windows smoke test.

    Repeatable, non-destructive checks for a packaged
    JieJieBox-Windows-amd64-test-*.zip. This script only inspects the package and
    the Windows proxy state; it never starts the GUI, never enables TUN and never
    changes the network configuration.

    Usage:

        powershell -NoProfile -ExecutionPolicy Bypass -File tools/smoke-test.ps1 `
            -ZipPath .\dist\JieJieBox-Windows-amd64-test-<shortSHA>.zip

    Exit code is 0 only when every executed check passed. Checks that could not run
    are reported as NOT RUN together with the reason, and never counted as PASS.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failures = New-Object System.Collections.Generic.List[string]
$notRun = New-Object System.Collections.Generic.List[string]

function Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "== $Title" -ForegroundColor Cyan
}

function Pass {
    param([string]$Message)
    Write-Host ("   PASS    {0}" -f $Message) -ForegroundColor Green
}

function Fail {
    param([string]$Message)
    $script:failures.Add($Message)
    Write-Host ("   FAIL    {0}" -f $Message) -ForegroundColor Red
}

function Skip {
    param([string]$Message)
    $script:notRun.Add($Message)
    Write-Host ("   NOT RUN {0}" -f $Message) -ForegroundColor Yellow
}

function Get-PeMachine {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if (($bytes.Length -lt 0x40) -or ($bytes[0] -ne 0x4D) -or ($bytes[1] -ne 0x5A)) {
        throw "Not a PE image: $Path"
    }
    $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
    if (($bytes[$peOffset] -ne 0x50) -or ($bytes[$peOffset + 1] -ne 0x45)) {
        throw "Missing PE signature: $Path"
    }
    return [System.BitConverter]::ToUInt16($bytes, $peOffset + 4)
}

# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ZipPath)) {
    Write-Host "smoke test: archive not found: $ZipPath" -ForegroundColor Red
    exit 1
}

$ZipPath = (Resolve-Path -LiteralPath $ZipPath).Path
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("jiejie-smoke-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

try {
    Section 'Package extraction'
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $workDir -Force
    $rootFiles = Get-ChildItem -LiteralPath $workDir
    Pass ("extracted {0} entries to a clean directory" -f $rootFiles.Count)

    $required = @('JieJieBox.exe', 'sing-box.exe', 'JieJieBox.ini', 'README.md',
        'BUILDINFO.txt', 'SHA256SUMS.txt', 'config.json')
    foreach ($name in $required) {
        if (Test-Path -LiteralPath (Join-Path $workDir $name)) {
            Pass "present: $name"
        }
        else {
            Fail "missing from the archive root: $name"
        }
    }

    Section 'PE architecture (both EXEs must be AMD64)'
    foreach ($name in @('JieJieBox.exe', 'sing-box.exe')) {
        $path = Join-Path $workDir $name
        if (-not (Test-Path -LiteralPath $path)) {
            Fail "$name is absent, cannot check its architecture"
            continue
        }
        $machine = Get-PeMachine -Path $path
        if ($machine -eq 0x8664) {
            Pass ("{0} is 0x8664 (AMD64)" -f $name)
        }
        else {
            Fail ("{0} machine is 0x{1:X4}, expected 0x8664" -f $name, $machine)
        }
    }

    Section 'Recorded hashes'
    $sumsPath = Join-Path $workDir 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $sumsPath)) {
        Fail 'SHA256SUMS.txt is missing'
    }
    else {
        foreach ($line in Get-Content -LiteralPath $sumsPath) {
            $trimmed = $line.Trim()
            if ($trimmed -eq '') { continue }
            $parts = $trimmed -split '\s+', 2
            if ($parts.Count -ne 2) { Fail "malformed SHA256SUMS.txt line: $trimmed"; continue }

            $expected = $parts[0].Trim().ToLowerInvariant()
            $file = $parts[1].Trim().TrimStart('*')
            $target = Join-Path $workDir $file
            if (-not (Test-Path -LiteralPath $target)) {
                Fail "SHA256SUMS.txt lists a missing file: $file"
                continue
            }
            $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -eq $expected) { Pass "sha256 ok: $file" } else { Fail "sha256 mismatch: $file" }
        }
    }

    Section 'Build metadata'
    $buildInfoPath = Join-Path $workDir 'BUILDINFO.txt'
    if (-not (Test-Path -LiteralPath $buildInfoPath)) {
        Fail 'BUILDINFO.txt is missing'
    }
    else {
        $buildInfo = Get-Content -LiteralPath $buildInfoPath -Raw
        foreach ($key in @('gui_commit', 'core_tag', 'core_sha256', 'core_version', 'pe_machine', 'signed')) {
            if ($buildInfo -match "(?m)^$key\s*=") { Pass "BUILDINFO has $key" } else { Fail "BUILDINFO lacks $key" }
        }
        if ($buildInfo -match '(?m)^signed\s*=\s*no') {
            Pass 'package is recorded as unsigned'
        }
        else {
            Fail 'BUILDINFO does not record signed = no'
        }
    }

    Section 'Core identity'
    $core = Join-Path $workDir 'sing-box.exe'
    if (Test-Path -LiteralPath $core) {
        $versionOutput = & $core version 2>&1
        if ($LASTEXITCODE -eq 0 -and $versionOutput) {
            Pass ("sing-box.exe version -> {0}" -f ($versionOutput | Select-Object -First 1))
        }
        else {
            Fail ("sing-box.exe version failed with exit code {0}" -f $LASTEXITCODE)
        }
    }
    else {
        Fail 'sing-box.exe is absent, cannot run its version command'
    }

    Section 'Windows system proxy state (read-only)'
    # Read the same per-connection option the application writes, so the report
    # captures the state before and after a manual GUI run.
    try {
        $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $props = Get-ItemProperty -Path $regPath -ErrorAction Stop
        $enabled = $props.ProxyEnable
        $server = $props.ProxyServer
        if ($enabled -eq 1) {
            Write-Host ("   INFO    system proxy is currently ON: {0}" -f $server)
        }
        else {
            Write-Host '   INFO    system proxy is currently OFF'
        }
        Write-Host ("   INFO    ProxyOverride: {0}" -f $props.ProxyOverride)
    }
    catch {
        Skip ("could not read the Windows proxy settings: {0}" -f $_.Exception.Message)
    }

    Section 'GUI behaviour (must be run by hand)'
    foreach ($item in @(
            'Launch JieJieBox.exe and confirm a tray icon appears with the correct status text',
            'Confirm the tray menu renders Chinese text without mojibake',
            'Confirm exactly one JieJieBox.exe and one sing-box.exe in Task Manager',
            'Double-click JieJieBox.exe again: the single-instance guard must refuse a second copy',
            'Exit from the tray menu and confirm sing-box.exe also terminates',
            'Confirm the Windows proxy setting is restored to the value recorded above',
            'For a TUN config: confirm exactly one UAC prompt and that declining it does not fall back silently'
        )) {
        Skip $item
    }
}
finally {
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host '--------------------------------------------'
if ($notRun.Count -gt 0) {
    Write-Host ("NOT RUN: {0} check(s) need a human on the desktop" -f $notRun.Count) -ForegroundColor Yellow
}
if ($failures.Count -gt 0) {
    Write-Host ("FAILED: {0}" -f $failures.Count) -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host 'All executed checks passed.' -ForegroundColor Green
exit 0
