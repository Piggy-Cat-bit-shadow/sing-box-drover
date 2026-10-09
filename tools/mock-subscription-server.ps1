<#
    Localhost mock subscription server for the JieJieBox lifecycle tests.

    Serves a valid sing-box JSON body so the one-shot profile update path can be
    exercised without touching a real airport subscription. Supported paths:

        /sub    immediate 200 with a valid config + Subscription-Userinfo header
        /slow   waits SlowSeconds before responding (exit-during-download)
        /403    403
        /500    500
        /bad    a truncated / invalid JSON body
        /abort  closes the connection without a complete body

    Writes mock-server.log so a harness can confirm it handled the requests it should
    have. Never logs request headers or anything credential-like.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File tools/mock-subscription-server.ps1 `
            -Port 18080 -BodyPath C:\src\mocksrv\sub.json
#>

[CmdletBinding()]
param(
    [int]$Port = 18080,
    [Parameter(Mandatory = $true)][string]$BodyPath,
    [int]$SlowSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$logPath = Join-Path (Split-Path $BodyPath -Parent) 'mock-server.log'
function LogLine {
    param([string]$Text)
    $stamp = (Get-Date).ToString('HH:mm:ss.fff')
    Add-Content -LiteralPath $logPath -Value "$stamp $Text"
}

$body = [IO.File]::ReadAllBytes($BodyPath)
$bad = [Text.Encoding]::UTF8.GetBytes('{"inbounds":[{"type":')

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
LogLine "listening on $Port (body $($body.Length) bytes)"

try {
    while ($listener.IsListening) {
        $ctx = $null
        try { $ctx = $listener.GetContext() } catch { break }
        if ($null -eq $ctx) { break }

        $path = $ctx.Request.Url.AbsolutePath
        LogLine "request $path"

        try {
            switch ($path) {
                '/403' { $ctx.Response.StatusCode = 403 }
                '/500' { $ctx.Response.StatusCode = 500 }
                '/slow' {
                    LogLine "slow: waiting $SlowSeconds s"
                    Start-Sleep -Seconds $SlowSeconds
                    $ctx.Response.StatusCode = 200
                    $ctx.Response.Headers.Add('Subscription-Userinfo', 'upload=1000; download=2000; total=10000; expire=1798761600')
                    $ctx.Response.ContentType = 'application/json'
                    $ctx.Response.ContentLength64 = $body.Length
                    $ctx.Response.OutputStream.Write($body, 0, $body.Length)
                    LogLine 'slow: body sent'
                }
                '/bad' {
                    $ctx.Response.StatusCode = 200
                    $ctx.Response.ContentType = 'application/json'
                    $ctx.Response.ContentLength64 = $bad.Length
                    $ctx.Response.OutputStream.Write($bad, 0, $bad.Length)
                }
                '/abort' {
                    $ctx.Response.StatusCode = 200
                    $ctx.Response.ContentLength64 = 100000
                    $ctx.Response.OutputStream.Write($body, 0, [Math]::Min(64, $body.Length))
                    $ctx.Response.Abort()
                }
                default {
                    $ctx.Response.StatusCode = 200
                    $ctx.Response.Headers.Add('Subscription-Userinfo', 'upload=1000; download=2000; total=10000; expire=1798761600')
                    $ctx.Response.ContentType = 'application/json'
                    $ctx.Response.ContentLength64 = $body.Length
                    $ctx.Response.OutputStream.Write($body, 0, $body.Length)
                }
            }
        }
        catch {
            LogLine "error handling $path : $($_.Exception.Message)"
        }
        finally {
            try { $ctx.Response.Close() } catch { }
        }
    }
}
finally {
    LogLine 'stopping'
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
}
