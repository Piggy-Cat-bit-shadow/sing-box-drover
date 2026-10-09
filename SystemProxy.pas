unit SystemProxy;

// Owns exactly one thing: the Windows per-connection proxy setting for the LAN
// connection, and only while this application is the one that changed it.
//
// The bug this design removes: the previous version restored the proxy by writing
// "direct access" unconditionally. That silently destroyed whatever the user (or
// another proxy tool such as Clash Verge) had configured. Here the original value
// is captured before the first change and restored afterwards, and the restore is
// skipped when something else has taken the setting over in the meantime - a
// third party's newer configuration always wins over our stale snapshot.

interface

// Applies the local proxy. The first successful call snapshots the previous
// Windows proxy configuration so that DisableSystemProxy can put it back.
function EnableSystemProxy(const host: string; port: word): boolean;

// Restores what was there before EnableSystemProxy, but only if our value is
// still in place. Returns True when the Windows setting is no longer ours.
function DisableSystemProxy: boolean;

// The proxy string this unit most recently applied ('' when none).
function AppliedProxyServer: string;

// The Windows proxy string currently configured ('' when direct access).
function CurrentProxyServer: string;

implementation

uses
  Windows, SysUtils, WinInet;

type
  INTERNET_PER_CONN_OPTION = record
    dwOption: DWORD;

    Value: record
      case Integer of
        1:
          (dwValue: DWORD);
        2:
          (pszValue: LPTSTR);
        3:
          (ftValue: TFileTime);
    end;
  end;

  LPINTERNET_PER_CONN_OPTION = ^INTERNET_PER_CONN_OPTION;

  INTERNET_PER_CONN_OPTION_LIST = record
    dwSize: DWORD;
    pszConnection: LPTSTR;
    dwOptionCount: DWORD;
    dwOptionError: DWORD;
    pOptions: LPINTERNET_PER_CONN_OPTION;
  end;

const
  INTERNET_PER_CONN_FLAGS = 1;
  INTERNET_PER_CONN_PROXY_SERVER = 2;
  INTERNET_PER_CONN_PROXY_BYPASS = 3;
  INTERNET_PER_CONN_AUTOCONFIG_URL = 4;
  INTERNET_PER_CONN_AUTODISCOVERY_FLAGS = 5;
  PROXY_TYPE_DIRECT = $00000001;
  PROXY_TYPE_PROXY = $00000002;
  PROXY_TYPE_AUTO_PROXY_URL = $00000004;
  PROXY_TYPE_AUTO_DETECT = $00000008;
  INTERNET_OPTION_REFRESH = 37;
  INTERNET_OPTION_PER_CONNECTION_OPTION = 75;
  INTERNET_OPTION_SETTINGS_CHANGED = 39;

var
  // Snapshot of the Windows proxy taken just before we changed it.
  GOriginalSaved: boolean = false;
  GOriginalFlags: DWORD = 0;
  GOriginalServer: string = '';
  GOriginalBypass: string = '';
  // What we last wrote, so a takeover by another tool can be detected.
  GAppliedServer: string = '';

function QueryProxy(out AFlags: DWORD; out AServer, ABypass: string): boolean;
var
  list: INTERNET_PER_CONN_OPTION_LIST;
  opts: array [0 .. 2] of INTERNET_PER_CONN_OPTION;
  size: DWORD;
begin
  result := false;
  AFlags := PROXY_TYPE_DIRECT;
  AServer := '';
  ABypass := '';

  ZeroMemory(@list, SizeOf(list));
  ZeroMemory(@opts, SizeOf(opts));

  list.dwSize := SizeOf(list);
  list.pszConnection := nil;
  list.dwOptionCount := 3;
  list.pOptions := @opts[0];

  opts[0].dwOption := INTERNET_PER_CONN_FLAGS;
  opts[1].dwOption := INTERNET_PER_CONN_PROXY_SERVER;
  opts[2].dwOption := INTERNET_PER_CONN_PROXY_BYPASS;

  size := SizeOf(list);
  if not InternetQueryOption(nil, INTERNET_OPTION_PER_CONNECTION_OPTION, @list, size) then
    exit;

  AFlags := opts[0].Value.dwValue;

  if opts[1].Value.pszValue <> nil then
  begin
    AServer := string(opts[1].Value.pszValue);
    // InternetQueryOption returns these strings from GlobalAlloc'd memory.
    GlobalFree(HLOCAL(opts[1].Value.pszValue));
  end;

  if opts[2].Value.pszValue <> nil then
  begin
    ABypass := string(opts[2].Value.pszValue);
    GlobalFree(HLOCAL(opts[2].Value.pszValue));
  end;

  result := true;
end;

function AppliedProxyServer: string;
begin
  result := GAppliedServer;
end;

function SetOptions(const proxyStr: string): boolean;
var
  list: INTERNET_PER_CONN_OPTION_LIST;
  opts: array [0 .. 2] of INTERNET_PER_CONN_OPTION;
begin
  ZeroMemory(@list, SizeOf(list));
  ZeroMemory(@opts, SizeOf(opts));

  list.dwSize := SizeOf(list);
  list.pszConnection := nil;
  list.pOptions := @opts[0];

  if proxyStr = '' then
  begin
    list.dwOptionCount := 1;
    opts[0].dwOption := INTERNET_PER_CONN_FLAGS;
    opts[0].Value.dwValue := PROXY_TYPE_DIRECT;
  end
  else
  begin
    list.dwOptionCount := 3;

    opts[0].dwOption := INTERNET_PER_CONN_FLAGS;
    opts[0].Value.dwValue := PROXY_TYPE_DIRECT or PROXY_TYPE_PROXY;

    opts[1].dwOption := INTERNET_PER_CONN_PROXY_SERVER;
    opts[1].Value.pszValue := PChar(proxyStr);

    opts[2].dwOption := INTERNET_PER_CONN_PROXY_BYPASS;
    opts[2].Value.pszValue := '<local>';
  end;

  result := InternetSetOption(nil, INTERNET_OPTION_PER_CONNECTION_OPTION, @list, SizeOf(list));

  if result then
  begin
    InternetSetOption(nil, INTERNET_OPTION_SETTINGS_CHANGED, nil, 0);
    InternetSetOption(nil, INTERNET_OPTION_REFRESH, nil, 0);
  end;
end;

function CurrentProxyServer: string;
var
  flags: DWORD;
  server, bypass: string;
begin
  result := '';
  if QueryProxy(flags, server, bypass) and ((flags and PROXY_TYPE_PROXY) <> 0) then
    result := server;
end;

// Re-applies the captured snapshot, including the bypass list and the connection
// flags, so PAC/auto-detect settings survive too.
function RestoreOriginal: boolean;
var
  list: INTERNET_PER_CONN_OPTION_LIST;
  opts: array [0 .. 3] of INTERNET_PER_CONN_OPTION;
  count: DWORD;
  server: string;
  bypass: string;
  flags: DWORD;
begin
  flags := GOriginalFlags;
  server := GOriginalServer;
  bypass := GOriginalBypass;

  ZeroMemory(@list, SizeOf(list));
  ZeroMemory(@opts, SizeOf(opts));

  list.dwSize := SizeOf(list);
  list.pszConnection := nil;
  list.pOptions := @opts[0];
  count := 0;

  opts[count].dwOption := INTERNET_PER_CONN_FLAGS;
  opts[count].Value.dwValue := flags;
  inc(count);

  // Only pass a proxy server string when the snapshot actually had one; an empty
  // string would be written verbatim instead of clearing the option.
  if (flags and PROXY_TYPE_PROXY) <> 0 then
  begin
    opts[count].dwOption := INTERNET_PER_CONN_PROXY_SERVER;
    opts[count].Value.pszValue := PChar(server);
    inc(count);
  end;

  if bypass <> '' then
  begin
    opts[count].dwOption := INTERNET_PER_CONN_PROXY_BYPASS;
    opts[count].Value.pszValue := PChar(bypass);
    inc(count);
  end;

  list.dwOptionCount := count;

  result := InternetSetOption(nil, INTERNET_OPTION_PER_CONNECTION_OPTION, @list, SizeOf(list));

  if result then
  begin
    InternetSetOption(nil, INTERNET_OPTION_SETTINGS_CHANGED, nil, 0);
    InternetSetOption(nil, INTERNET_OPTION_REFRESH, nil, 0);
  end;
end;

function EnableSystemProxy(const host: string; port: word): boolean;
var
  valueStr, proxyStr: string;
  flags: DWORD;
  server, bypass: string;
begin
  valueStr := Format('%s:%d', [host, port]);
  proxyStr := Format('http=%s;https=%s;socks=%s', [valueStr, valueStr, valueStr]);

  // Snapshot only on the first change, and never overwrite an existing snapshot:
  // re-enabling after a second core start must still restore the *user's* value,
  // not one of our own earlier values.
  if (not GOriginalSaved) and QueryProxy(flags, server, bypass) then
  begin
    GOriginalFlags := flags;
    GOriginalServer := server;
    GOriginalBypass := bypass;
    GOriginalSaved := true;
  end;

  result := SetOptions(proxyStr);
  if result then
    GAppliedServer := proxyStr;
end;

function DisableSystemProxy: boolean;
var
  current: string;
begin
  // If another tool has since written its own proxy, leave it alone: our snapshot
  // is stale and restoring it would clobber a newer, deliberate configuration.
  current := CurrentProxyServer;
  if (current <> '') and (not SameText(current, GAppliedServer)) then
  begin
    GAppliedServer := '';
    result := true;
    exit;
  end;

  if GOriginalSaved then
    result := RestoreOriginal
  else
    // Nothing was ever captured, so there is nothing of ours to undo.
    result := true;

  GAppliedServer := '';
end;

end.
