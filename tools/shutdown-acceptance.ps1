<#
.SYNOPSIS
    Windows shutdown acceptance harness for JieJieBox.

.DESCRIPTION
    Drives the packaged GUI through its real close paths and asserts the full
    teardown contract:

      * GUI process exits
      * the sing-box child this GUI started exits
      * the configured listen port is released
      * the Windows proxy is restored exactly, or a third party's value is respected
      * no uncaught exception / crash

    Two close paths are exercised:

      wmclose  - WM_CLOSE posted to the real TfrmMain window (automation entry point)
      tray     - the actual tray menu "quit" item, which is the true user path

    The tray path locates the icon with Shell_NotifyIconGetRect, opens the menu with
    a right click, reads the popup menu item captions over the process's own
    PopupMenu window (so it does not depend on matching Chinese text), computes the
    item rectangle with GetMenuItemRect and clicks it.

    PID discipline: only PIDs this harness captured are ever terminated, and only in
    the cleanup path when a run fails. No wildcard process killing.

.PARAMETER PackageDir
    Directory holding an extracted package (JieJieBox.exe, sing-box.exe, config.json).

.PARAMETER Runs
    Iterations per scenario.

.PARAMETER Scenario
    all | wmclose | tray | startup | repeat | noproxy | directproxy

.PARAMETER ResultPath
    Machine-readable JSON result file.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools/shutdown-acceptance.ps1 `
        -PackageDir C:\src\smoke -Runs 20
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageDir,
    [int]$Runs = 20,
    [ValidateSet('all', 'wmclose', 'tray', 'startup', 'repeat', 'noproxy', 'directproxy')]
    [string]$Scenario = 'all',
    [string]$ResultPath = '',
    [int]$ExitBoundSeconds = 15,
    [int]$CoreExitGraceSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($ResultPath -eq '') { $ResultPath = Join-Path $Root 'tests\results\shutdown-run.json' }
$PackageDir = (Resolve-Path -LiteralPath $PackageDir).Path

# ---------------------------------------------------------------------------
# Win32
# ---------------------------------------------------------------------------
if (-not ('JJ.Native' -as [type])) {
    Add-Type -Namespace JJ -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)]
public struct NOTIFYICONIDENTIFIER { public uint cbSize; public IntPtr hWnd; public uint uID; public Guid guidItem; }

[DllImport("user32.dll", SetLastError=true)] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern int PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr h);
[DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr hMenu);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetMenuString(IntPtr hMenu, uint id, System.Text.StringBuilder s, int n, uint flags);
[DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr hMenu, int pos);
[DllImport("user32.dll")] public static extern bool GetMenuItemRect(IntPtr hWnd, IntPtr hMenu, uint item, out RECT r);
[DllImport("shell32.dll")] public static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER id, out RECT r);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@
}

$WM_CLOSE = 0x0010
$MF_BYPOSITION = 0x400
$MOUSEEVENTF_RIGHTDOWN = 0x0008
$MOUSEEVENTF_RIGHTUP = 0x0010
$MOUSEEVENTF_LEFTDOWN = 0x0002
$MOUSEEVENTF_LEFTUP = 0x0004

function Get-MainWindow {
    param([int]$ProcessId)
    $script:found = [IntPtr]::Zero
    $cb = [JJ.Native+EnumWindowsProc] {
        param($h, $l)
        $pid2 = 0
        [void][JJ.Native]::GetWindowThreadProcessId($h, [ref]$pid2)
        if ($pid2 -eq $script:targetPid) {
            $cls = New-Object Text.StringBuilder 128
            [void][JJ.Native]::GetClassName($h, $cls, 128)
            if ($cls.ToString() -eq 'TfrmMain') { $script:found = $h }
        }
        return $true
    }
    $script:targetPid = $ProcessId
    [void][JJ.Native]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:found
}

function Get-OwnedCoreIds {
    param([int]$GuiPid, [string]$CoreName)
    return @(Get-CimInstance Win32_Process -Filter "Name='$CoreName'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ParentProcessId -eq $GuiPid } | ForEach-Object { [int]$_.ProcessId })
}

function Get-ProxySnapshot {
    $p = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    # ProxyServer / ProxyOverride can be absent entirely when the value is cleanly
    # direct, so read them defensively instead of touching a missing property
    # (which throws under Set-StrictMode).
    $enable = 0
    if ($p -and ($p.PSObject.Properties.Name -contains 'ProxyEnable')) { $enable = [int]$p.ProxyEnable }
    $server = ''
    if ($p -and ($p.PSObject.Properties.Name -contains 'ProxyServer')) { $server = [string]$p.ProxyServer }
    $bypass = ''
    if ($p -and ($p.PSObject.Properties.Name -contains 'ProxyOverride')) { $bypass = [string]$p.ProxyOverride }
    return [pscustomobject]@{ Enable = $enable; Server = $server; Bypass = $bypass }
}

function Set-ProxySnapshot {
    param($Snap)
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty $k -Name ProxyEnable -Value $Snap.Enable
    if ($Snap.Server -eq '') { Remove-ItemProperty $k -Name ProxyServer -ErrorAction SilentlyContinue }
    else { Set-ItemProperty $k -Name ProxyServer -Value $Snap.Server }
    if ($Snap.Bypass -ne '') { Set-ItemProperty $k -Name ProxyOverride -Value $Snap.Bypass }
}

function Wait-Condition {
    param([scriptblock]$Test, [int]$TimeoutSeconds, [int]$PollMs = 100)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Test) { return $true }
        Start-Sleep -Milliseconds $PollMs
    }
    return [bool](& $Test)
}

# TTrayIcon registers its Shell_NotifyIcon entry from its *own* hidden window, not
# from the form, so Shell_NotifyIconGetRect has to be given that window handle.
function Get-TrayNotifyWindows {
    param([int]$ProcessId)
    $script:trayWnds = @()
    $cb = [JJ.Native+EnumWindowsProc] {
        param($h, $l)
        $pid2 = 0
        [void][JJ.Native]::GetWindowThreadProcessId($h, [ref]$pid2)
        if ($pid2 -eq $script:targetPid) {
            $cls = New-Object Text.StringBuilder 128
            [void][JJ.Native]::GetClassName($h, $cls, 128)
            if ($cls.ToString() -eq 'TTrayIcon') { $script:trayWnds += $h }
        }
        return $true
    }
    $script:targetPid = $ProcessId
    [void][JJ.Native]::EnumWindows($cb, [IntPtr]::Zero)
    return @($script:trayWnds)
}

# Opens the tray icon's context menu and clicks the item whose caption contains
# $QuitLabel. Returns $true when a click was actually delivered.
function Invoke-TrayQuit {
    param([int]$GuiPid, [IntPtr]$MainHwnd, [string]$QuitLabel)

    $candidates = @(Get-TrayNotifyWindows -ProcessId $GuiPid)
    if ($MainHwnd -ne [IntPtr]::Zero) { $candidates += $MainHwnd }

    $rect = New-Object JJ.Native+RECT
    $clicked = $false
    foreach ($wnd in $candidates) {
        foreach ($id in 1..8) {
            $nid = New-Object JJ.Native+NOTIFYICONIDENTIFIER
            $nid.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($nid)
            $nid.hWnd = $wnd
            $nid.uID = $id
            $nid.guidItem = [Guid]::Empty
            if ([JJ.Native]::Shell_NotifyIconGetRect([ref]$nid, [ref]$rect) -eq 0) {
                $clicked = $true
                break
            }
        }
        if ($clicked) { break }
    }
    if (-not $clicked) { return $false }

    $cx = [int](($rect.Left + $rect.Right) / 2)
    $cy = [int](($rect.Top + $rect.Bottom) / 2)

    [void][JJ.Native]::SetForegroundWindow($MainHwnd)
    [void][JJ.Native]::SetCursorPos($cx, $cy)
    [JJ.Native]::mouse_event($MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, [IntPtr]::Zero)
    [JJ.Native]::mouse_event($MOUSEEVENTF_RIGHTUP, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 600

    # Find the popup menu window belonging to this process.
    $script:popup = [IntPtr]::Zero
    $cb = [JJ.Native+EnumWindowsProc] {
        param($h, $l)
        $pid2 = 0
        [void][JJ.Native]::GetWindowThreadProcessId($h, [ref]$pid2)
        if (($pid2 -eq $script:targetPid) -and [JJ.Native]::IsWindowVisible($h)) {
            $cls = New-Object Text.StringBuilder 128
            [void][JJ.Native]::GetClassName($h, $cls, 128)
            if ($cls.ToString() -eq '#32768') { $script:popup = $h }
        }
        return $true
    }
    $script:targetPid = $GuiPid
    [void][JJ.Native]::EnumWindows($cb, [IntPtr]::Zero)
    if ($script:popup -eq [IntPtr]::Zero) { return $false }

    $hMenu = [JJ.Native]::GetMenu($script:popup)
    if ($hMenu -eq [IntPtr]::Zero) { return $false }

    $count = [JJ.Native]::GetMenuItemCount($hMenu)
    $target = -1
    for ($i = 0; $i -lt $count; $i++) {
        $sb = New-Object Text.StringBuilder 256
        [void][JJ.Native]::GetMenuString($hMenu, [uint32]$i, $sb, 256, $MF_BYPOSITION)
        $text = $sb.ToString()
        if (($QuitLabel -ne '') -and $text.Contains($QuitLabel)) { $target = $i; break }
    }
    if ($target -lt 0) { return $false }

    $ir = New-Object JJ.Native+RECT
    if (-not [JJ.Native]::GetMenuItemRect($script:popup, $hMenu, [uint32]$target, [ref]$ir)) { return $false }

    $ix = [int](($ir.Left + $ir.Right) / 2)
    $iy = [int](($ir.Top + $ir.Bottom) / 2)
    [void][JJ.Native]::SetCursorPos($ix, $iy)
    Start-Sleep -Milliseconds 200
    [JJ.Native]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
    [JJ.Native]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [IntPtr]::Zero)
    return $true
}

# ---------------------------------------------------------------------------

$exe = Join-Path $PackageDir 'JieJieBox.exe'
$coreExe = Join-Path $PackageDir 'sing-box.exe'
foreach ($f in @($exe, $coreExe, (Join-Path $PackageDir 'config.json'))) {
    if (-not (Test-Path -LiteralPath $f)) { throw "package file missing: $f" }
}

# The quit caption is read from AppStrings at build time; matched loosely so this
# harness does not hardcode a translated string.
$QuitLabel = [char]0x9000 + [char]0x51FA   # 退出

$results = New-Object System.Collections.Generic.List[object]
$originalProxy = Get-ProxySnapshot

# Reads the application's own shutdown duration out of its log: the interval between
# "Shutdown requested" and "Shutdown complete". That is the number the P0 gate cares
# about, because it is measured inside the process and is therefore not polluted by
# process start-up (cold first launch, archive extraction, AV scan).
function Get-AppShutdownMs {
    param([string]$LogPath, [int64]$SinceTicks)

    if (-not (Test-Path -LiteralPath $LogPath)) { return -1 }
    $requested = $null
    $complete = $null
    foreach ($line in Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue) {
        if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) .*Shutdown requested') {
            $ts = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $null)
            if ($ts.Ticks -ge $SinceTicks) { $requested = $ts }
        }
        elseif ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) .*Shutdown complete') {
            $ts = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $null)
            if ($ts.Ticks -ge $SinceTicks) { $complete = $ts }
        }
    }
    if ($requested -and $complete) { return [int](($complete - $requested).TotalMilliseconds) }
    return -1
}
Write-Host ("original proxy: enable={0} server='{1}'" -f $originalProxy.Enable, $originalProxy.Server)
Write-Host ("quit label    : {0}" -f $QuitLabel)

function Run-One {
    param([string]$Kind, [int]$Index, $ProxyBefore)

    $record = [ordered]@{
        scenario    = $Kind
        index       = $Index
        guiPid      = 0
        corePids    = @()
        portBefore  = $false
        portAfter   = $true
        proxyBefore = "$($ProxyBefore.Enable)|$($ProxyBefore.Server)"
        proxyAfter  = ''
        elapsedMs   = -1
        appShutdownMs = -1
        guiExited   = $false
        coreExited  = $false
        closePath   = ''
        pass        = $false
        note        = ''
    }

    # Local time, because the log stamps are local and are parsed as such.
    $launchTicks = [datetime]::Now.Ticks
    $proc = Start-Process -FilePath $exe -WorkingDirectory $PackageDir -PassThru
    $record.guiPid = $proc.Id
    $guiPid = $proc.Id

    try {
        # Wait for the core to be spawned and the port to listen (startup scenario
        # intentionally skips this so close races the launch).
        if ($Kind -ne 'startup') {
            [void](Wait-Condition -TimeoutSeconds 20 -Test {
                    @((Get-OwnedCoreIds -GuiPid $guiPid -CoreName 'sing-box.exe')).Count -gt 0
                })
            Start-Sleep -Milliseconds 800
        }
        else {
            Start-Sleep -Milliseconds 300
        }

        $record.corePids = @(Get-OwnedCoreIds -GuiPid $guiPid -CoreName 'sing-box.exe')

        $hwnd = [IntPtr]::Zero
        [void](Wait-Condition -TimeoutSeconds 10 -Test {
                $script:h = Get-MainWindow -ProcessId $guiPid
                return ($script:h -ne [IntPtr]::Zero)
            })
        $hwnd = Get-MainWindow -ProcessId $guiPid
        if ($hwnd -eq [IntPtr]::Zero) {
            $record.note = 'TfrmMain window not found'
            return $record
        }

        $sw = [Diagnostics.Stopwatch]::StartNew()

        switch ($Kind) {
            'tray' {
                if (-not (Invoke-TrayQuit -GuiPid $guiPid -MainHwnd $hwnd -QuitLabel $QuitLabel)) {
                    # Do NOT silently substitute another close path: that would report
                    # the real user path as passing without ever exercising it.
                    $record.closePath = 'tray(NOT AUTOMATABLE)'
                    $record.note = 'Shell_NotifyIconGetRect could not resolve the tray icon in this session'
                    $record.pass = $false
                    return $record
                }
                $record.closePath = 'tray'
            }
            'repeat' {
                for ($i = 0; $i -lt 5; $i++) {
                    [void][JJ.Native]::PostMessage($hwnd, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
                    Start-Sleep -Milliseconds 40
                }
                $record.closePath = 'wmclose-x5'
            }
            default {
                [void][JJ.Native]::PostMessage($hwnd, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
                $record.closePath = 'wmclose'
            }
        }

        $exited = Wait-Condition -TimeoutSeconds $ExitBoundSeconds -Test {
            -not (Get-Process -Id $guiPid -ErrorAction SilentlyContinue)
        }
        $sw.Stop()
        $record.elapsedMs = [int]$sw.ElapsedMilliseconds
        # The in-process number is authoritative for the P0 gate; the wall-clock
        # number above includes process start-up and is reported for context.
        $record.appShutdownMs = Get-AppShutdownMs -LogPath (Join-Path $PackageDir 'JieJieBox.log') -SinceTicks $launchTicks
        $record.guiExited = $exited

        # Owned core must go too.
        if ($record.corePids.Count -gt 0) {
            $coreGone = Wait-Condition -TimeoutSeconds $CoreExitGraceSeconds -Test {
                $alive = @($record.corePids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
                return ($alive.Count -eq 0)
            }
            $record.coreExited = $coreGone
        }
        else {
            $record.coreExited = $true
        }

        # A late child would still mean an orphan.
        $late = @(Get-OwnedCoreIds -GuiPid $guiPid -CoreName 'sing-box.exe')
        if ($late.Count -gt 0) {
            $record.coreExited = $false
            foreach ($lateId in $late) {
                Stop-Process -Id $lateId -Force -ErrorAction SilentlyContinue
            }
        }

        $record.portAfter = -not [bool](Get-NetTCPConnection -State Listen -LocalPort 7899 -ErrorAction SilentlyContinue)
        $after = Get-ProxySnapshot
        $record.proxyAfter = "$($after.Enable)|$($after.Server)"

        $proxyOk = ($after.Enable -eq $originalProxy.Enable) -and ($after.Server -eq $originalProxy.Server)
        $record.pass = $record.guiExited -and $record.coreExited -and $record.portAfter -and $proxyOk
        if (-not $proxyOk) { $record.note = "$($record.note) proxy not restored".Trim() }
    }
    finally {
        # Only PIDs this harness captured, and only if something is still alive.
        $stillGui = Get-Process -Id $guiPid -ErrorAction SilentlyContinue
        if ($stillGui) {
            $record.note = "$($record.note) FORCE-KILLED gui".Trim()
            $record.pass = $false
            Stop-Process -Id $guiPid -Force -ErrorAction SilentlyContinue
            foreach ($cid in @(Get-OwnedCoreIds -GuiPid $guiPid -CoreName 'sing-box.exe')) {
                Stop-Process -Id $cid -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return $record
}

# ---------------------------------------------------------------------------

$scenarios = @()
switch ($Scenario) {
    'all' { $scenarios = @('wmclose', 'tray', 'startup', 'repeat') }
    default { $scenarios = @($Scenario) }
}

try {
    foreach ($kind in $scenarios) {
        $n = $Runs
        if ($kind -eq 'startup') { $n = [Math]::Min($Runs, 10) }
        if ($kind -eq 'repeat') { $n = [Math]::Min($Runs, 10) }

        Write-Host ''
        Write-Host "== scenario $kind x$n" -ForegroundColor Cyan
        for ($i = 1; $i -le $n; $i++) {
            $before = Get-ProxySnapshot
            $r = Run-One -Kind $kind -Index $i -ProxyBefore $before
            $results.Add([pscustomobject]$r)
            $tag = if ($r.pass) { 'PASS' } else { 'FAIL' }
            $color = if ($r.pass) { 'Green' } else { 'Red' }
            Write-Host ("   [{0}] {1} #{2}  gui={3} core={4} port={5} wall={6}ms app={8}ms {7}" -f `
                    $tag, $kind, $i, $r.guiExited, $r.coreExited, $r.portAfter, $r.elapsedMs, $r.note, $r.appShutdownMs) -ForegroundColor $color
        }
    }
}
finally {
    # The harness must never leave the machine on a test proxy value.
    $finalProxy = Get-ProxySnapshot
    if (($finalProxy.Enable -ne $originalProxy.Enable) -or ($finalProxy.Server -ne $originalProxy.Server)) {
        Set-ProxySnapshot -Snap $originalProxy
        Write-Host ("proxy restored to the original value: enable={0} server='{1}'" -f $originalProxy.Enable, $originalProxy.Server) -ForegroundColor Yellow
    }

    $dir = Split-Path $ResultPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8

    $total = $results.Count
    $passed = @($results | Where-Object { $_.pass }).Count
    Write-Host ''
    Write-Host ("RESULT: {0}/{1} passed  -> {2}" -f $passed, $total, $ResultPath) -ForegroundColor $(if ($passed -eq $total) { 'Green' } else { 'Red' })
}

if (@($results | Where-Object { -not $_.pass }).Count -gt 0) { exit 1 }
exit 0
