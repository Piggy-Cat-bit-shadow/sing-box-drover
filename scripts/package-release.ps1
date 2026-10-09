<#
.SYNOPSIS
    Builds the JieJieBox GUI and produces a complete, self-contained release zip.

.DESCRIPTION
    Steps:
      1. locate a Delphi installation and build the project (Release, Win64)
      2. fetch + SHA256-verify the custom sing-box core (scripts/fetch-core.ps1)
      3. assemble dist\<Version>\ with the GUI, core, config files and docs
      4. write a resource script and compile it with brcc32 (the Windows
         resource compiler that ships with RAD Studio) so the contents can be
         opened by an executable
      5. zip the result

    The core is never updated at runtime: whatever this script locked in is what
    the shipped package contains.

.PARAMETER Config
    Build configuration. Default: Release.

.PARAMETER Platform
    Target platform. Default: Win64.

.PARAMETER Version
    Version string used for the output folder and zip name. Default: read from
    app.res's stamped version, falling back to v0.1.5.

.PARAMETER SkipBuild
    Reuse an already built JieJieBox.exe.

.PARAMETER SkipCore
    Reuse an already fetched sing-box.exe instead of contacting GitHub.

.PARAMETER CoreTag
    Pin a specific core release tag (passed through to fetch-core.ps1).

.EXAMPLE
    pwsh -File scripts/package-release.ps1
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
$DefaultVersion = 'v0.1.5'

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Find-Delphi {
    $candidates = @(
        "$env:ProgramFiles\Embarcadero\Studio\23.0\bin",
        "$env:ProgramFiles\Embarcadero\Studio\22.0\bin",
        "${env:ProgramFiles(x86)}\Embarcadero\Studio\23.0\bin",
        "${env:ProgramFiles(x86)}\Embarcadero\Studio\22.0\bin"
    )

    if ($env:BDS) {
        $candidates = @($env:BDS) + $candidates
    }

    foreach ($dir in $candidates) {
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            return (Resolve-Path -LiteralPath $dir).Path
        }
    }

    # Last resort: derive it from the registry.
    foreach ($hive in @('HKLM:\SOFTWARE\Embarcadero\BDS', 'HKLM:\SOFTWARE\WOW6432Node\Embarcadero\BDS')) {
        if (-not (Test-Path $hive)) { continue }
        foreach ($key in Get-ChildItem -Path $hive -ErrorAction SilentlyContinue) {
            $root = (Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue).RootDir
            if ($root) {
                $bin = Join-Path $root 'bin'
                if (Test-Path -LiteralPath $bin) { return $bin }
            }
        }
    }

    return ''
}

function Invoke-DelphiBuild {
    param([string]$BdsBin)

    $msbuild = Get-Command 'msbuild.exe' -ErrorAction SilentlyContinue
    if (-not $msbuild -and $BdsBin) {
        # RAD Studio ships an rsvars.bat that prepares the MSBuild environment.
        $rsvars = Join-Path (Split-Path $BdsBin -Parent) 'rsvars.bat'
        if (Test-Path -LiteralPath $rsvars) {
            Write-Host "    using $rsvars"
            $cmd = "call `"$rsvars`" >nul && msbuild `"$ProjectFile`" /t:Build /p:Config=$Config /p:Platform=$Platform /v:minimal /nologo"
            & cmd.exe /c $cmd
            if ($LASTEXITCODE -ne 0) {
                throw "MSBuild failed with exit code $LASTEXITCODE."
            }
            return
        }
    }

    if ($msbuild) {
        & $msbuild.Source $ProjectFile "/t:Build" "/p:Config=$Config" "/p:Platform=$Platform" '/v:minimal' '/nologo'
        if ($LASTEXITCODE -ne 0) {
            throw "MSBuild failed with exit code $LASTEXITCODE."
        }
        return
    }

    if ($BdsBin) {
        $bds = Join-Path $BdsBin 'bds.exe'
        if (Test-Path -LiteralPath $bds) {
            & $bds -b -pDelphi -ns $ProjectFile
            if ($LASTEXITCODE -ne 0) {
                throw "bds.exe build failed with exit code $LASTEXITCODE."
            }
            return
        }
    }

    throw 'No Delphi build tool found. Install RAD Studio or pass -SkipBuild with a prebuilt JieJieBox.exe.'
}

try {
    Write-Step "JieJieBox release packaging"
    Write-Host "    root: $Root"

    # --- 1. build ----------------------------------------------------------
    $builtExe = Join-Path $Root "$Platform\$Config\$PackageName.exe"
    if (-not $SkipBuild) {
        $bdsBin = Find-Delphi
        if ($bdsBin -eq '') {
            throw 'No RAD Studio installation detected. Pass -SkipBuild to package an existing JieJieBox.exe.'
        }
        Write-Host "    Delphi: $bdsBin"
        Write-Step "Building $PackageName ($Config, $Platform)"
        Invoke-DelphiBuild -BdsBin $bdsBin
    }

    if (-not (Test-Path -LiteralPath $builtExe)) {
        throw "GUI executable not found: $builtExe"
    }
    Write-Host "    exe: $builtExe"

    # --- 2. core -----------------------------------------------------------
    if (-not $SkipCore) {
        $fetchArgs = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'fetch-core.ps1'), '-OutputDir', $Root)
        if ($CoreTag -ne '') {
            $fetchArgs += @('-Tag', $CoreTag)
        }
        Write-Step 'Fetching the custom core'
        & pwsh @fetchArgs
        if ($LASTEXITCODE -ne 0) {
            throw 'fetch-core.ps1 failed.'
        }
    }

    $coreExe = Join-Path $Root 'sing-box.exe'
    if (-not (Test-Path -LiteralPath $coreExe)) {
        throw "Core executable not found: $coreExe"
    }

    $coreStamp = @{}
    $stampPath = Join-Path $Root 'core.txt'
    if (Test-Path -LiteralPath $stampPath) {
        foreach ($line in Get-Content -LiteralPath $stampPath) {
            $kv = $line -split '=', 2
            if ($kv.Count -eq 2) { $coreStamp[$kv[0].Trim()] = $kv[1].Trim() }
        }
    }
    $coreTag = if ($coreStamp.ContainsKey('tag')) { $coreStamp['tag'] } else { 'unknown' }
    $coreVersion = if ($coreStamp.ContainsKey('version')) { $coreStamp['version'] } else { '' }
    $coreSha = if ($coreStamp.ContainsKey('asset_sha256')) { $coreStamp['asset_sha256'] } else { '' }

    if ($Version -eq '') { $Version = $DefaultVersion }

    $distRoot = Join-Path $Root 'dist'
    $stageDir = Join-Path $distRoot $Version
    if (Test-Path -LiteralPath $stageDir) {
        Remove-Item -LiteralPath $stageDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    # --- 3. assemble -------------------------------------------------------
    Write-Step "Staging $stageDir"
    Copy-Item -LiteralPath $builtExe -Destination (Join-Path $stageDir "$PackageName.exe") -Force
    Copy-Item -LiteralPath $coreExe -Destination (Join-Path $stageDir 'sing-box.exe') -Force
    Copy-Item -LiteralPath (Join-Path $Root 'config.json') -Destination $stageDir -Force
    Copy-Item -LiteralPath (Join-Path $Root "$PackageName.ini") -Destination $stageDir -Force
    Copy-Item -LiteralPath (Join-Path $Root 'README.md') -Destination $stageDir -Force

    New-Item -ItemType Directory -Path (Join-Path $stageDir 'profiles') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $stageDir 'profiles\.keep') -Value '' -Encoding ASCII

    $notes = @(
        "$PackageName for Windows $Version",
        '',
        "core repo    : $($coreStamp['repo'])",
        "core tag     : $coreTag",
        "core asset   : $($coreStamp['asset'])",
        "core sha256  : $coreSha",
        "core version : $coreVersion",
        '',
        'The bundled core is the custom fork build. It is pinned at build time;',
        'this client never updates the core at runtime.',
        '',
        'Reminder: the upstream project (hdrover/sing-box-drover) ships no explicit',
        'open-source licence. Confirm the licensing situation before any public',
        'redistribution of this package.'
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath (Join-Path $stageDir 'RELEASE-NOTES.txt') -Value $notes -Encoding UTF8

    $configOnlyDir = Join-Path $distRoot "$PackageName-$Version-config"
    if (Test-Path -LiteralPath $configOnlyDir) {
        Remove-Item -LiteralPath $configOnlyDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $configOnlyDir -Force | Out-Null
    Copy-Item -LiteralPath $builtExe -Destination (Join-Path $configOnlyDir "$PackageName.exe") -Force
    Copy-Item -LiteralPath (Join-Path $Root 'config.json') -Destination $configOnlyDir -Force
    Copy-Item -LiteralPath (Join-Path $Root "$PackageName.ini") -Destination $configOnlyDir -Force
    Copy-Item -LiteralPath (Join-Path $Root 'README.md') -Destination $configOnlyDir -Force
    Set-Content -LiteralPath (Join-Path $configOnlyDir 'RELEASE-NOTES.txt') -Value $notes -Encoding UTF8

    # --- 4. resource script so the zip can be opened by an executable ------
    Write-Step 'Compiling the package resource script'
    $brcc32 = ''
    $bdsBinForRes = Find-Delphi
    if ($bdsBinForRes -ne '') {
        $candidate = Join-Path $bdsBinForRes 'brcc32.exe'
        if (Test-Path -LiteralPath $candidate) { $brcc32 = $candidate }
    }

    if ($brcc32 -eq '') {
        Write-Warning 'brcc32.exe not found; the zip will be produced without an executable opener.'
    }
    else {
        $rcPath = Join-Path $distRoot "$PackageName-$Version.rc"
        $rcLines = @(
            "1 ICON `"$Root\icon.ico`"",
            "2 ICON `"$Root\icon_disabled.ico`"",
            "3 ICON `"$Root\icon_tun.ico`""
        )
        $id = 100
        $extras = @('RELEASE-NOTES.txt', 'config.json', "$PackageName.ini", 'README.md')
        foreach ($extra in $extras) {
            $id++
            $rcLines += "$id RCDATA `"$Root\$extra`""
        }
        $rcLines += "200 VERSIONINFO"
        $rcLines += 'FILEVERSION 0,1,5,0'
        $rcLines += 'PRODUCTVERSION 0,1,5,0'
        $rcLines += 'FILEFLAGSMASK 0x3fL'
        $rcLines += 'FILEFLAGS 0x0L'
        $rcLines += 'FILEOS 0x40004L'
        $rcLines += 'FILETYPE 0x1L'
        $rcLines += 'FILESUBTYPE 0x0L'
        $rcLines += 'BEGIN'
        $rcLines += '  BLOCK "StringFileInfo"'
        $rcLines += '  BEGIN'
        $rcLines += '    BLOCK "040904b0"'
        $rcLines += '    BEGIN'
        $rcLines += "      VALUE `"FileDescription`", `"$PackageName for Windows`""
        $rcLines += "      VALUE `"FileVersion`", `"$Version`""
        $rcLines += "      VALUE `"ProductName`", `"$PackageName`""
        $rcLines += "      VALUE `"ProductVersion`", `"$Version`""
        $rcLines += "      VALUE `"Comments`", `"core $coreTag`""
        $rcLines += '    END'
        $rcLines += '  END'
        $rcLines += '  BLOCK "VarFileInfo"'
        $rcLines += '  BEGIN'
        $rcLines += '    VALUE "Translation", 0x409, 1200'
        $rcLines += '  END'
        $rcLines += 'END'

        Set-Content -LiteralPath $rcPath -Value ($rcLines -join [Environment]::NewLine) -Encoding ASCII

        Push-Location $distRoot
        try {
            & $brcc32 (Split-Path $rcPath -Leaf) | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "brcc32 failed with exit code $LASTEXITCODE; continuing without the opener."
                $brcc32 = ''
            }
            else {
                Write-Host "    resource compiled"
            }
        }
        finally {
            Pop-Location
        }

        if ($brcc32 -ne '') {
            # Append the compiled resource to a copy of the GUI so Explorer can
            # show the icon and offer "open with" for the archive.
            $resName = [System.IO.Path]::GetFileNameWithoutExtension($rcPath) + '.res'
            $resPath = Join-Path $distRoot $resName
            $openerPath = Join-Path $distRoot "$PackageName-$Version-opener.exe"

            Copy-Item -LiteralPath (Join-Path $stageDir "$PackageName.exe") -Destination $openerPath -Force

            $stream = [System.IO.File]::Open($openerPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
            try {
                $bytes = [System.IO.File]::ReadAllBytes($resPath)
                $stream.Write($bytes, 0, $bytes.Length)
            }
            finally {
                $stream.Dispose()
            }

            # NTStruc: 8 bytes magic + 4 bytes image size + at 0x3C the PE offset.
            $header = [System.IO.File]::ReadAllBytes($openerPath)
            $peOffset = [System.BitConverter]::ToInt32($header, 0x3C)
            $magic = [System.BitConverter]::ToUInt16($header, $peOffset + 24)
            $checksumOffset =
                if ($magic -eq 0x20B) { $peOffset + 0x58 }   # PE32+
                elseif ($magic -eq 0x10B) { $peOffset + 0x58 } # PE32
                else { -1 }

            if ($checksumOffset -gt 0) {
                $checksum = [System.BitConverter]::ToUInt32($header, $checksumOffset)
                if ($checksum -ne 0) {
                    $checksum = $checksum + $bytes.Length - ($bytes.Length % 2)
                }
                $patch = [System.BitConverter]::GetBytes([uint32]$checksum)
                $fs = [System.IO.File]::Open($openerPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write)
                try {
                    $fs.Seek($checksumOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
                    $fs.Write($patch, 0, 4)
                }
                finally {
                    $fs.Dispose()
                }
            }

            Write-Host "    opener: $openerPath"
        }
    }

    # --- 5. zip ------------------------------------------------------------
    Write-Step 'Creating the archives'
    $zipPath = Join-Path $distRoot "$PackageName-$Version.zip"
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $zipPath -CompressionLevel Optimal

    $configZipPath = Join-Path $distRoot "$PackageName-$Version-config-only.zip"
    if (Test-Path -LiteralPath $configZipPath) {
        Remove-Item -LiteralPath $configZipPath -Force
    }
    Compress-Archive -Path (Join-Path $configOnlyDir '*') -DestinationPath $configZipPath -CompressionLevel Optimal

    Write-Host ''
    Write-Host 'package ready' -ForegroundColor Green
    Write-Host "  $zipPath"
    Write-Host "  $configZipPath"
    Write-Host "  core: $coreTag ($coreSha)"

    exit 0
}
catch {
    Write-Host ''
    Write-Host "package-release failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
