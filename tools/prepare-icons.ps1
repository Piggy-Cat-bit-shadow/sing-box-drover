<#
.SYNOPSIS
    Rewrites the project .ico files so every entry is a BMP/DIB image.

.DESCRIPTION
    Why this exists
    ---------------
    Modern .ico files store the large 256x256 image as a PNG rather than as a DIB.
    Borland's resource compiler (brcc32), which ships with RAD Studio and is the
    only resource compiler guaranteed to produce a .res layout that RLINK32 accepts,
    cannot read PNG-compressed icon entries: it fails with "Allocate failed".

    This script decodes each PNG entry with System.Drawing and re-encodes it as a
    32-bit BGRA DIB, leaving the entries that are already DIBs untouched. The result
    is a functionally identical icon that brcc32 can compile.

    The rewritten icons are written to tools/icons/ so the originals in the
    repository root stay untouched; tools/app.rc points at the rewritten copies.

.PARAMETER SourceDir
    Directory holding the original .ico files. Defaults to the repository root.

.PARAMETER DestDir
    Directory that receives the rewritten .ico files. Defaults to tools/icons.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools/prepare-icons.ps1
#>

[CmdletBinding()]
param(
    [string]$SourceDir = '',
    [string]$DestDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($SourceDir -eq '') { $SourceDir = $Root }
if ($DestDir -eq '') { $DestDir = Join-Path $Root 'tools\icons' }
if (-not (Test-Path -LiteralPath $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
}

function Convert-PngToDib {
    param([byte[]]$Png)
    $in = New-Object System.IO.MemoryStream(, $Png)
    try {
        $bmp = [System.Drawing.Bitmap]::FromStream($in)
        try {
            $out = New-Object System.IO.MemoryStream
            try {
                $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Bmp)
                $file = $out.ToArray()
            }
            finally { $out.Dispose() }
        }
        finally { $bmp.Dispose() }
    }
    finally { $in.Dispose() }

    if (($file.Length -lt 14) -or ($file[0] -ne 0x42) -or ($file[1] -ne 0x4D)) {
        throw 'System.Drawing did not produce a BMP stream.'
    }
    # Drop the 14-byte BITMAPFILEHEADER: an ICO entry stores the DIB directly.
    return [byte[]]$file[14..($file.Length - 1)]
}

function Convert-Icon {
    param([string]$Path, [string]$OutPath)

    $raw = [IO.File]::ReadAllBytes($Path)
    $reserved = [BitConverter]::ToUInt16($raw, 0)
    $type = [BitConverter]::ToUInt16($raw, 2)
    $count = [BitConverter]::ToUInt16($raw, 4)
    if ($reserved -ne 0 -or $type -ne 1) { throw "$Path is not an icon file." }

    $entries = @()
    for ($i = 0; $i -lt $count; $i++) {
        $off = 6 + ($i * 16)
        $entries += , @{
            width   = $raw[$off]
            height  = $raw[$off + 1]
            colors  = $raw[$off + 2]
            planes  = [BitConverter]::ToUInt16($raw, $off + 4)
            bpp     = [BitConverter]::ToUInt16($raw, $off + 6)
            size    = [BitConverter]::ToUInt32($raw, $off + 8)
            offset  = [BitConverter]::ToUInt32($raw, $off + 12)
        }
    }

    $images = @()
    $converted = 0
    foreach ($e in $entries) {
        $data = [byte[]]$raw[$e.offset..($e.offset + $e.size - 1)]
        $isPng = ($data.Length -ge 8) -and ($data[0] -eq 0x89) -and ($data[1] -eq 0x50) -and
                 ($data[2] -eq 0x4E) -and ($data[3] -eq 0x47)
        if ($isPng) {
            $data = Convert-PngToDib -Png $data
            $converted++
        }
        $images += , $data
    }

    # Rebuild: ICONDIR, ICONDIRENTRY per image, then the image payloads.
    $out = New-Object System.Collections.Generic.List[byte]
    foreach ($v in @([uint16]0, [uint16]1, [uint16]$entries.Count)) {
        foreach ($b in [BitConverter]::GetBytes($v)) { [void]$out.Add($b) }
    }

    $dataOffset = 6 + ($entries.Count * 16)
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        $data = $images[$i]
        [void]$out.Add([byte]$e.width)
        [void]$out.Add([byte]$e.height)
        [void]$out.Add([byte]$e.colors)
        [void]$out.Add([byte]0)     # reserved
        foreach ($b in [BitConverter]::GetBytes([uint16]$e.planes)) { [void]$out.Add($b) }
        foreach ($b in [BitConverter]::GetBytes([uint16]$e.bpp)) { [void]$out.Add($b) }
        foreach ($b in [BitConverter]::GetBytes([uint32]$data.Length)) { [void]$out.Add($b) }
        foreach ($b in [BitConverter]::GetBytes([uint32]$dataOffset)) { [void]$out.Add($b) }
        $dataOffset += $data.Length
    }

    foreach ($data in $images) {
        foreach ($b in $data) { [void]$out.Add($b) }
    }

    [IO.File]::WriteAllBytes($OutPath, $out.ToArray())
    return $converted
}

foreach ($name in @('icon.ico', 'icon_disabled.ico', 'icon_tun.ico')) {
    $src = Join-Path $SourceDir $name
    if (-not (Test-Path -LiteralPath $src)) { throw "missing icon: $src" }
    $dst = Join-Path $DestDir $name
    $converted = Convert-Icon -Path $src -OutPath $dst
    Write-Host ("{0,-20} -> {1}  (png entries converted: {2})" -f $name, $dst, $converted)
}
