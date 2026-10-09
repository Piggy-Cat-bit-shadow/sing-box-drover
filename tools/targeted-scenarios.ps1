<#
    Targeted P0 scenarios that the main harness does not cover:

        thirdparty  - while the app owns the proxy, another tool writes its own value;
                      the app must NOT overwrite it on exit            (spec: >= 3)
        missingcore - sing-box.exe is absent, so the app cannot start a core at all;
                      it must not leave an unresponsive GUI and must not
                      damage the proxy                                 (spec: >= 5)
        startfail   - the core cannot bind its inbound, so sing-box exits immediately;
                      shutdown must still complete                      (spec: >= 5)

    PID discipline: only PIDs captured by this script are ever terminated.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageDir,
    [int]$Runs = 5,
    [ValidateSet('thirdparty', 'missingcore', 'startfail')]
    [string]$Scenario = 'thirdparty',
    [string]$ResultPath = '',
    [int]$ExitBoundSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($ResultPath -eq '') { $ResultPath = Join-Path $Root 'tests\results\targeted.json' }
$PackageDir = (Resolve-Path -LiteralPath $PackageDir).Path
$ProxyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$Port = 7899

if (-not ('JJ2.Native' -as [type])) {
    Add-Type -Namespace JJ2 -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true)] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern int PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
'@
}

function Get-Windows {
    param([int]$ProcessId)
    $script:rows = @()
    $cb = [JJ2.Native+EnumWindowsProc] {
        param($h, $l)
        $pid2 = 0
        [void][JJ2.Native]::GetWindowThreadProcessId($h, [ref]$pid2)
        if ($pid2 -eq $script:tgt) {
            $cn = New-Object Text.StringBuilder 128; [void][JJ2.Native]::GetClassName($h, $cn, 128)
            $tt = New-Object Text.StringBuilder 512; [void][JJ2.Native]::GetWindowText($h, $tt, 512)
            $script:rows += [pscustomobject]@{ Handle = $h; Class = $cn.ToString(); Title = $tt.ToString() }
        }
        return $true
    }
    $script:tgt = $ProcessId
    [void][JJ2.Native]::EnumWindows($cb, [IntPtr]::Zero)
    return @($script:rows)
}

function Get-Proxy {
    $p = Get-ItemProperty $ProxyKey -ErrorAction SilentlyContinue
    $e = 0; $s = ''
    if ($p -and ($p.PSObject.Properties.Name -contains 'ProxyEnable')) { $e = [int]$p.ProxyEnable }
    if ($p -and ($p.PSObject.Properties.Name -contains 'ProxyServer')) { $s = [string]$p.ProxyServer }
    return [pscustomobject]@{ Enable = $e; Server = $s }
}

function Get-OwnedCores {
    param([int]$GuiPid)
    return @(Get-CimInstance Win32_Process -Filter "Name='sing-box.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ParentProcessId -eq $GuiPid } | ForEach-Object { [int]$_.ProcessId })
}

$exe = Join-Path $PackageDir 'JieJieBox.exe'
$core = Join-Path $PackageDir 'sing-box.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "missing $exe" }

$records = New-Object System.Collections.Generic.List[object]
$original = Get-Proxy
Write-Host ("original proxy: enable={0} server='{1}'" -f $original.Enable, $original.Server)

$coreBackup = "$core.bak"
$listener = $null

try {
    for ($i = 1; $i -le $Runs; $i++) {
        $rec = [ordered]@{
            scenario = $Scenario; index = $i; guiPid = 0
            guiExited = $false; elapsedMs = -1; appShutdownMs = -1
            coreChildren = 0; lateCores = 0; portFree = $true
            proxyBefore = ''; proxyAfter = ''; proxyExpected = ''
            dialogSeen = $false; pass = $false; note = ''
        }

        # --- scenario-specific preparation -------------------------------
        switch ($Scenario) {
            'thirdparty' {
                Set-ItemProperty $ProxyKey -Name ProxyEnable -Value 1
                Set-ItemProperty $ProxyKey -Name ProxyServer -Value 'http://127.0.0.1:7890'
            }
            'missingcore' {
                Set-ItemProperty $ProxyKey -Name ProxyEnable -Value 1
                Set-ItemProperty $ProxyKey -Name ProxyServer -Value 'http://127.0.0.1:7890'
                if (Test-Path -LiteralPath $core) { Move-Item -LiteralPath $core -Destination $coreBackup -Force }
            }
            'startfail' {
                Set-ItemProperty $ProxyKey -Name ProxyEnable -Value 1
                Set-ItemProperty $ProxyKey -Name ProxyServer -Value 'http://127.0.0.1:7890'
                # Occupy the inbound port so sing-box exits immediately.
                $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse('127.0.0.1'), $Port)
                $listener.Start()
            }
        }

        $before = Get-Proxy
        $rec.proxyBefore = "$($before.Enable)|$($before.Server)"
        $launch = [datetime]::Now.Ticks
        $proc = Start-Process -FilePath $exe -WorkingDirectory $PackageDir -PassThru
        $rec.guiPid = $proc.Id
        $guiPid = $proc.Id

        try {
            Start-Sleep -Seconds 5
            $rec.coreChildren = @(Get-OwnedCores -GuiPid $guiPid).Count

            if ($Scenario -eq 'thirdparty') {
                # Another tool takes the setting over while we run.
                Set-ItemProperty $ProxyKey -Name ProxyServer -Value 'http://127.0.0.1:9999'
                $rec.proxyExpected = '1|http://127.0.0.1:9999'
            }
            elseif ($Scenario -eq 'missingcore') {
                $rec.proxyExpected = "$($original.Enable)|$($original.Server)"
            }
            else {
                $rec.proxyExpected = '1|http://127.0.0.1:7890'
            }

            # Ask it to close: prefer WM_CLOSE, otherwise dismiss the fatal dialog.
            $wins = Get-Windows -ProcessId $guiPid
            $main = $wins | Where-Object { $_.Class -eq 'TfrmMain' } | Select-Object -First 1
            $dialog = $wins | Where-Object { $_.Class -eq '#32770' } | Select-Object -First 1
            if ($dialog) {
                $rec.dialogSeen = $true
                $rec.note = 'fatal dialog shown'
                [void][JJ2.Native]::PostMessage($dialog.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
            }
            elseif ($main) {
                [void][JJ2.Native]::PostMessage($main.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
            }
            else {
                $rec.note = 'no TfrmMain and no dialog found'
            }

            $sw = [Diagnostics.Stopwatch]::StartNew()
            $exited = $false
            for ($j = 0; $j -lt ($ExitBoundSeconds * 5); $j++) {
                Start-Sleep -Milliseconds 200
                if (-not (Get-Process -Id $guiPid -ErrorAction SilentlyContinue)) { $exited = $true; break }
                # A dialog can appear slightly later; try to dismiss it once.
                if ((-not $rec.dialogSeen) -and ($j -gt 10)) {
                    $d2 = Get-Windows -ProcessId $guiPid | Where-Object { $_.Class -eq '#32770' } | Select-Object -First 1
                    if ($d2) {
                        $rec.dialogSeen = $true
                        $rec.note = "$($rec.note) fatal dialog shown(late)".Trim()
                        [void][JJ2.Native]::PostMessage($d2.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
                    }
                }
            }
            $sw.Stop()
            $rec.elapsedMs = [int]$sw.ElapsedMilliseconds
            $rec.guiExited = $exited

            if (Test-Path -LiteralPath (Join-Path $PackageDir 'JieJieBox.log')) {
                $logLines = Get-Content -LiteralPath (Join-Path $PackageDir 'JieJieBox.log') -ErrorAction SilentlyContinue
                $req = $null; $done = $null
                foreach ($line in $logLines) {
                    if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) .*Shutdown requested') {
                        $ts = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $null)
                        if ($ts.Ticks -ge $launch) { $req = $ts }
                    }
                    elseif ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) .*Shutdown complete') {
                        $ts = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $null)
                        if ($ts.Ticks -ge $launch) { $done = $ts }
                    }
                }
                if ($req -and $done) { $rec.appShutdownMs = [int](($done - $req).TotalMilliseconds) }
            }

            $rec.lateCores = @(Get-OwnedCores -GuiPid $guiPid).Count
            foreach ($lc in @(Get-OwnedCores -GuiPid $guiPid)) { Stop-Process -Id $lc -Force -ErrorAction SilentlyContinue }
            $rec.portFree = -not [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)

            $after = Get-Proxy
            $rec.proxyAfter = "$($after.Enable)|$($after.Server)"
            $rec.pass = $rec.guiExited -and ($rec.lateCores -eq 0) -and ($rec.proxyAfter -eq $rec.proxyExpected)
        }
        finally {
            if (Get-Process -Id $guiPid -ErrorAction SilentlyContinue) {
                $rec.note = "$($rec.note) FORCE-KILLED".Trim()
                $rec.pass = $false
                Stop-Process -Id $guiPid -Force -ErrorAction SilentlyContinue
                foreach ($c in @(Get-OwnedCores -GuiPid $guiPid)) { Stop-Process -Id $c -Force -ErrorAction SilentlyContinue }
            }
            if ($Scenario -eq 'missingcore') {
                if (Test-Path -LiteralPath $coreBackup) { Move-Item -LiteralPath $coreBackup -Destination $core -Force }
            }
            if ($listener) { try { $listener.Stop() } catch { }; $listener = $null }
            Start-Sleep -Milliseconds 400
        }

        $records.Add([pscustomobject]$rec)
        $tag = if ($rec.pass) { 'PASS' } else { 'FAIL' }
        $col = if ($rec.pass) { 'Green' } else { 'Red' }
        Write-Host ("   [{0}] {1} #{2} gui={3} cores={4} late={5} dialog={6} app={7}ms proxy {8} -> {9} (want {10}) {11}" -f `
                $tag, $Scenario, $i, $rec.guiExited, $rec.coreChildren, $rec.lateCores, $rec.dialogSeen, `
                $rec.appShutdownMs, $rec.proxyBefore, $rec.proxyAfter, $rec.proxyExpected, $rec.note) -ForegroundColor $col
    }
}
finally {
    if (Test-Path -LiteralPath $coreBackup) { Move-Item -LiteralPath $coreBackup -Destination $core -Force }
    if ($listener) { try { $listener.Stop() } catch { } }
    # Never leave the machine on a test proxy value.
    $fin = Get-Proxy
    if (($fin.Enable -ne $original.Enable) -or ($fin.Server -ne $original.Server)) {
        Set-ItemProperty $ProxyKey -Name ProxyEnable -Value $original.Enable
        if ($original.Server -eq '') { Remove-ItemProperty $ProxyKey -Name ProxyServer -ErrorAction SilentlyContinue }
        else { Set-ItemProperty $ProxyKey -Name ProxyServer -Value $original.Server }
        Write-Host "proxy restored to the original value" -ForegroundColor Yellow
    }

    $dir = Split-Path $ResultPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $records | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    $passed = @($records | Where-Object { $_.pass }).Count
    Write-Host ("RESULT: {0}/{1} passed -> {2}" -f $passed, $records.Count, $ResultPath) -ForegroundColor $(if ($passed -eq $records.Count) { 'Green' } else { 'Red' })
}

if (@($records | Where-Object { -not $_.pass }).Count -gt 0) { exit 1 }
exit 0
