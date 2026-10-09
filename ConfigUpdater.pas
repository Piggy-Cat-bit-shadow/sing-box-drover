unit ConfigUpdater;

// Single worker thread that owns *all* remote profile updates.
//
// Both the automatic interval and the manual "update now" action drive this one thread, so
// there is never a second HTTP request and never two writers for the same BPF.
// A candidate config is validated before it replaces anything, and nothing is
// written at all when the download or validation fails.
//
// The worker knows nothing about the GUI: it reports results through
// TConfigUpdateNotify, which TDrover marshals back to the main thread.

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs,
  System.Net.HttpClient, System.Net.URLClient, Logger, SingBoxCli, SingBoxConfig,
  SingBoxBpf;

type
  TConfigUpdateOutcome = (cuoIdle, cuoUpdating, cuoSuccess, cuoFailed);

  // One update attempt has finished. AProfile/ATraffic for a failed attempt are
  // meaningless and must be ignored by the receiver.
  TConfigUpdateNotify = procedure(const AFilePath: string; ASuccess: boolean; const AError: string;
    const AProfile: TBpfProfile; const ATraffic: TSubscriptionUserInfo) of object;

  TConfigUpdater = class(TThread)
  private
    FFilePath: string;
    FRemotePath: string;
    FIntervalMs: cardinal;
    FSingBoxCli: TSingBoxCli;
    FLogger: TLogger;
    FWorkDir: string;
    FOnNotify: TConfigUpdateNotify;
    FStopEvent: TEvent;
    FWakeEvent: TEvent;
    // Signalled by TerminatedSet. A third handle is required because
    // WaitForMultipleObjects cannot observe TThread.Terminated on its own.
    FCancelEvent: TEvent;
    FRequest: IHTTPRequest;
    FRequestLock: TCriticalSection;
    FPendingLock: TCriticalSection;
    FUpdatePending: integer;
    FLastUpdated: int64;
    FLastOutcome: TConfigUpdateOutcome;
    FLastError: string;
    FHandleRedirects: boolean;
    // When True this instance never runs its own scheduling loop; it exists only to
    // serve synchronous DownloadProfile calls from a one-shot worker thread.
    //
    // Without this, creating a TConfigUpdater for a one-shot download ALSO started a
    // fully functional automatic-update thread with the same file path, so two
    // threads could run FetchAndStore against the same BPF. The 60 s initial delay
    // only made that collision unlikely, it did not prevent it.
    FOneShotOnly: boolean;
    // Non-zero while a fetch is in progress. Held for the whole
    // download/validate/commit sequence so two callers can never write the same BPF.
    FFetchLock: TCriticalSection;

    function BuildUserAgent: string;
    function FetchAndStore(out AError: string; out AProfile: TBpfProfile;
      out ATraffic: TSubscriptionUserInfo): boolean;
    procedure ClearActiveRequest;
    procedure RequestUpdate;
    function ConsumePendingUpdate: boolean;
    procedure ClearPendingUpdates;
    function IntervalElapsed: boolean;
    procedure DoUpdate;
    procedure Notify(const AProfile: TBpfProfile; const ATraffic: TSubscriptionUserInfo;
      ASuccess: boolean; const AError: string);
    procedure Log(const AMessage: string);
  protected
    procedure Execute; override;
    procedure TerminatedSet; override;
  public
    // AHandleRedirects defaults to True: airport subscription URLs redirect as a
    // rule, and a one-shot worker has nothing to gain from refusing them.
    //
    // This replaced a THTTPRedirectPolicy parameter. No such type (and no
    // THTTPClient.RedirectPolicy property) exists in this Delphi version; the
    // supported API is the Boolean THTTPClient.HandleRedirects, which is what the
    // old "Always" default meant anyway.
    constructor Create(const AFilePath, ARemotePath: string; AIntervalMinutes: int32;
      ALastUpdated: int64; ASingBoxCli: TSingBoxCli; ALogger: TLogger; const AWorkDir: string;
      AHandleRedirects: boolean = true);
    destructor Destroy; override;

    // Disables this instance's own scheduling loop, leaving it usable only through
    // DownloadProfile. Used by the one-shot profile worker so that a single download
    // never coexists with an automatic-update thread for the same BPF.
    procedure MakeOneShotOnly;

    // Asks for an immediate update. Cheap, thread-safe and never starts a second
    // worker: it only wakes the existing one.
    procedure UpdateNow;

    // One-shot synchronous download for a profile that is not the active one.
    // Only the *file* is touched: the caller decides what to do with the result,
    // and the running core is never involved. Returns False and fills AError on
    // any failure (HTTP, validation, disk), leaving the old profile intact.
    function DownloadProfile(out AError: string; out ATraffic: TSubscriptionUserInfo): boolean;

    property OnNotify: TConfigUpdateNotify read FOnNotify write FOnNotify;
    property LastUpdated: int64 read FLastUpdated;
    property LastOutcome: TConfigUpdateOutcome read FLastOutcome;
    property LastError: string read FLastError;
  end;

implementation

uses
  System.DateUtils, System.IOUtils, System.StrUtils,
  ConfigReader;

const
  INITIAL_DELAY_MS = 60000;
  MIN_INTERVAL_MINUTES = 15;
  MS_PER_MINUTE = 60000;
  CONNECTION_TIMEOUT_MS = 15000;
  SEND_TIMEOUT_MS = 15000;
  RESPONSE_TIMEOUT_MS = 30000;

  USERINFO_HEADER = 'Subscription-Userinfo';

  // `expire` is a Unix timestamp in *seconds*. Anything at or below this value is
  // not a usable date (it would render as 1970 or earlier), so it is treated as
  // "no expiry information" rather than shown as a valid date.
  EXPIRE_MIN_PLAUSIBLE = int64(100000000); // 1973-03-03, well before any real subscription

function ClampIntervalMs(AIntervalMinutes: int32): cardinal;
var
  minutes: int64;
begin
  minutes := AIntervalMinutes;
  if minutes < MIN_INTERVAL_MINUTES then
    minutes := MIN_INTERVAL_MINUTES;

  result := cardinal(minutes * MS_PER_MINUTE);
end;

function UnixMsNow: int64;
begin
  result := DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now), false) * 1000;
end;

// The `expire` field of the `Subscription-Userinfo` header is a Unix timestamp in
// seconds. It is *not* a .NET DateTime tick count: real subscriptions send values
// like 1798761600, which as ticks would sit far below the .NET epoch and would
// previously collapse to 0, silently hiding the expiry from the UI.
//
// Every malformed input maps to 0 ("unknown"), which callers render as "no expiry":
//   - missing / empty / whitespace
//   - non-numeric text, or trailing garbage such as "1798761600Z"
//   - zero, negative values
//   - values that overflow Int64
//   - implausibly small values that cannot be a real Unix second timestamp
// A bad `expire` must never fail the download; the other traffic fields are
// parsed independently.
function ParseUserinfoExpire(const AValue: string): int64;
var
  text: string;
  value: int64;
begin
  result := 0;

  text := trim(AValue);
  if text = '' then
    exit;

  // StrToInt64Def returns the default instead of raising on non-numeric input and
  // on Int64 overflow, which is exactly the behaviour wanted here.
  value := StrToInt64Def(text, 0);

  if value < EXPIRE_MIN_PLAUSIBLE then
    exit;

  result := value;
end;

procedure ParseSubscriptionUserInfo(const AHeader: string; out AInfo: TSubscriptionUserInfo);
var
  parts: TArray<string>;
  part: string;
  eq: integer;
  key, value: string;
  parsed: int64;
begin
  AInfo := Default (TSubscriptionUserInfo);
  if trim(AHeader) = '' then
    exit;

  parts := AHeader.Split([';']);
  for part in parts do
  begin
    eq := Pos('=', part);
    if eq < 2 then
      continue;

    key := trim(Copy(part, 1, eq - 1));
    value := trim(Copy(part, eq + 1, MaxInt));

    if SameText(key, 'upload') then
    begin
      parsed := StrToInt64Def(value, 0);
      if parsed > 0 then
        AInfo.upload := parsed;
    end
    else if SameText(key, 'download') then
    begin
      parsed := StrToInt64Def(value, 0);
      if parsed > 0 then
        AInfo.download := parsed;
    end
    else if SameText(key, 'total') then
    begin
      parsed := StrToInt64Def(value, 0);
      if parsed > 0 then
        AInfo.total := parsed;
    end
    else if SameText(key, 'expire') then
      AInfo.expire := ParseUserinfoExpire(value);
  end;
end;

constructor TConfigUpdater.Create(const AFilePath, ARemotePath: string; AIntervalMinutes: int32;
  ALastUpdated: int64; ASingBoxCli: TSingBoxCli; ALogger: TLogger; const AWorkDir: string;
  AHandleRedirects: boolean);
begin
  FFilePath := AFilePath;
  FRemotePath := ARemotePath;
  FHandleRedirects := AHandleRedirects;
  FIntervalMs := ClampIntervalMs(AIntervalMinutes);
  FLastUpdated := ALastUpdated;
  FSingBoxCli := ASingBoxCli;
  FLogger := ALogger;
  FWorkDir := AWorkDir;
  FLastOutcome := cuoIdle;
  FLastError := '';
  FUpdatePending := 0;

  FStopEvent := TEvent.Create(nil, true, false, '');
  FWakeEvent := TEvent.Create(nil, true, false, '');
  FCancelEvent := TEvent.Create(nil, true, false, '');
  FRequestLock := TCriticalSection.Create;
  FPendingLock := TCriticalSection.Create;
  FFetchLock := TCriticalSection.Create;
  FOneShotOnly := false;

  FreeOnTerminate := false;
  inherited Create(false);
end;

// Reconfigures an already-constructed updater for one-shot use: its scheduling loop
// exits immediately instead of arming an interval timer for this same file.
//
// This must be called before anything can depend on the loop being idle. It is
// called from TProfileUpdateThread.Create right after construction; the scheduler
// cannot have reached its first update because Execute begins with a 60 s initial
// wait that TerminatedSet and the FOneShotOnly check both interrupt.
procedure TConfigUpdater.MakeOneShotOnly;
begin
  FOneShotOnly := true;
  // Wake the loop so it observes the flag without waiting for the initial delay.
  FCancelEvent.SetEvent;
end;

destructor TConfigUpdater.Destroy;
begin
  Terminate;
  FStopEvent.SetEvent;
  FWakeEvent.SetEvent;
  FCancelEvent.SetEvent;
  WaitFor;

  FreeAndNil(FStopEvent);
  FreeAndNil(FWakeEvent);
  FreeAndNil(FCancelEvent);
  FreeAndNil(FRequestLock);
  FreeAndNil(FPendingLock);
  FreeAndNil(FFetchLock);

  inherited;
end;

procedure TConfigUpdater.UpdateNow;
begin
  RequestUpdate;
end;

procedure TConfigUpdater.RequestUpdate;
begin
  if Terminated then
    exit;

  FPendingLock.Enter;
  try
    inc(FUpdatePending);
  finally
    FPendingLock.Leave;
  end;

  FWakeEvent.SetEvent;
end;

function TConfigUpdater.ConsumePendingUpdate: boolean;
begin
  result := false;

  FPendingLock.Enter;
  try
    if FUpdatePending > 0 then
    begin
      dec(FUpdatePending);
      result := true;
    end;
  finally
    FPendingLock.Leave;
  end;

  // Only clear the wake event once we know whether more work is queued, so a
  // request arriving during an update cannot be lost.
  if not result then
  begin
    FPendingLock.Enter;
    try
      if FUpdatePending = 0 then
        FWakeEvent.ResetEvent;
    finally
      FPendingLock.Leave;
    end;
  end;
end;

procedure TConfigUpdater.ClearPendingUpdates;
begin
  FPendingLock.Enter;
  try
    FUpdatePending := 0;
  finally
    FPendingLock.Leave;
  end;
end;

function TConfigUpdater.IntervalElapsed: boolean;
var
  elapsed: int64;
begin
  if FLastUpdated <= 0 then
    exit(true);

  elapsed := UnixMsNow - FLastUpdated;
  if elapsed < 0 then
    exit(true);

  result := elapsed >= int64(FIntervalMs);
end;

// Waits on the stop, wake and cancel handles directly through
// WaitForMultipleObjects. The previous implementation called
// TWaitResult.Poll(handles, timeout), a class function that does not exist in
// this Delphi version, so this loop could never have compiled.
//
// WAIT_OBJECT_0 is the stop handle and WAIT_OBJECT_0 + 2 is the cancel handle, so
// a stop request always wins over a concurrent wake.
//
// GetTickCount64 is used because, unlike GetTickCount, it cannot wrap, so a
// long-running updater never mis-computes its remaining timeout.
procedure TConfigUpdater.Execute;
var
  handles: array [0 .. 2] of THandle;
  waitResult: DWORD;
  deadline: UInt64;
  remaining: int64;
begin
  Log(format('Updater started for "%s" (interval %d min).', [FFilePath, FIntervalMs div MS_PER_MINUTE]));

  handles[0] := FStopEvent.Handle;
  handles[1] := FWakeEvent.Handle;
  handles[2] := FCancelEvent.Handle;

  // A one-shot instance must never arm an interval for this file: the outer worker
  // owns the download for its lifetime.
  if FOneShotOnly then
  begin
    Log('Updater is one-shot only; scheduling loop not started.');
    exit;
  end;

  // The first check is delayed so a restart does not hammer the subscription host.
  waitResult := WaitForMultipleObjects(3, @handles[0], false, INITIAL_DELAY_MS);
  if (waitResult = WAIT_OBJECT_0) or (waitResult = WAIT_OBJECT_0 + 2) then
    exit;

  // MakeOneShotOnly may have been called while the initial wait was still running.
  if FOneShotOnly then
  begin
    Log('Updater switched to one-shot only; scheduling loop not started.');
    exit;
  end;

  while not Terminated do
  begin
    if not IntervalElapsed then
    begin
      // Wait up to a full interval, waking whenever an event fires. Polling at
      // 250 ms keeps the deadline honest without busy-waiting.
      deadline := GetTickCount64 + FIntervalMs;
      repeat
        if Terminated then
          break;

        waitResult := WaitForMultipleObjects(3, @handles[0], false, 250);

        if (waitResult <> WAIT_TIMEOUT) and (waitResult <> WAIT_OBJECT_0 + 2) then
          break;

        remaining := int64(deadline) - int64(GetTickCount64);
      until remaining <= 0;

      if Terminated then
        break;
    end;

    // Recompute: the wait may have ended on the interval, on a wake, or on a stop.
    if (waitResult = WAIT_OBJECT_0) or (waitResult = WAIT_OBJECT_0 + 2) then
      break;

    if waitResult = WAIT_OBJECT_0 + 1 then
    begin
      // A wake was requested by the manual action or by the scheduler.
      if ConsumePendingUpdate or IntervalElapsed then
        DoUpdate;
      continue;
    end;

    // Either the interval expired or the deadline elapsed on its own.
    if IntervalElapsed then
    begin
      ClearPendingUpdates;
      DoUpdate;
    end;
  end;

  Log('Updater stopping...');
  Log('Updater stopped.');
end;

procedure TConfigUpdater.TerminatedSet;
var
  request: IHTTPRequest;
begin
  inherited;

  FStopEvent.SetEvent;
  FWakeEvent.SetEvent;
  FCancelEvent.SetEvent;

  FRequestLock.Enter;
  try
    request := FRequest;
  finally
    FRequestLock.Leave;
  end;

  if Assigned(request) then
  begin
    Log('Cancelling active request.');
    try
      request.Cancel;
    except
    end;
  end;
end;

procedure TConfigUpdater.ClearActiveRequest;
begin
  FRequestLock.Enter;
  try
    FRequest := nil;
  finally
    FRequestLock.Leave;
  end;
end;

function TConfigUpdater.BuildUserAgent: string;
var
  version: string;
begin
  result := 'JieJieBox';
  version := FSingBoxCli.GetVersion;
  if version <> '' then
    result := result + ' (sing-box ' + version + ')';
end;

// Downloads, validates and persists the remote profile. Returns False and fills
// AError on any failure; in that case nothing on disk has been touched.
function TConfigUpdater.FetchAndStore(out AError: string; out AProfile: TBpfProfile;
  out ATraffic: TSubscriptionUserInfo): boolean;
var
  http: THTTPClient;
  response: IHTTPResponse;
  jsonText: string;
  candidate: TSingBoxConfig;
  headerValue: string;
  header: TNetHeader;
  checkOutput: string;
begin
  result := false;
  AError := '';
  AProfile := Default (TBpfProfile);
  ATraffic := Default (TSubscriptionUserInfo);

  // Serialize the whole download -> validate -> commit sequence. Two callers (the
  // automatic interval and a manual one-shot) could otherwise both pass validation
  // and then both write this same BPF file.
  FFetchLock.Enter;

  try
    http := THTTPClient.Create;
    try
      http.UserAgent := BuildUserAgent;
      http.ConnectionTimeout := CONNECTION_TIMEOUT_MS;
      http.SendTimeout := SEND_TIMEOUT_MS;
      http.ResponseTimeout := RESPONSE_TIMEOUT_MS;
      http.HandleRedirects := FHandleRedirects;

      FRequestLock.Enter;
      try
        if Terminated then
        begin
          AError := 'Update cancelled.';
          exit;
        end;
        FRequest := http.GetRequest(sHTTPMethodGet, FRemotePath);
      finally
        FRequestLock.Leave;
      end;

      try
        response := http.Execute(FRequest);
      finally
        ClearActiveRequest;
      end;
    finally
      http.Free;
    end;

    if Terminated then
    begin
      AError := 'Update cancelled.';
      exit;
    end;

    if response.StatusCode div 100 <> 2 then
      raise Exception.CreateFmt('HTTP %d.', [response.StatusCode]);

    jsonText := response.ContentAsString(TEncoding.UTF8);

    // Traffic metadata is a bonus: a missing header never fails the update.
    try
      for header in response.Headers do
        if SameText(header.Name, USERINFO_HEADER) then
        begin
          headerValue := header.Value;
          ParseSubscriptionUserInfo(headerValue, ATraffic);
          break;
        end;
    except
      ATraffic := Default (TSubscriptionUserInfo);
    end;

    // --- validation happens before anything on disk is touched ---------------
    candidate := ConfigReader.ReadSingBoxConfig(jsonText);

    if FSingBoxCli <> nil then
    begin
      checkOutput := '';
      if not FSingBoxCli.CheckConfig(jsonText, FWorkDir, checkOutput) then
      begin
        if trim(checkOutput) <> '' then
          raise Exception.Create('sing-box check failed: ' + trim(checkOutput));
        raise Exception.Create('sing-box check failed.');
      end;
    end;

    if Terminated then
    begin
      AError := 'Update cancelled.';
      exit;
    end;

    // --- commit ------------------------------------------------------------
    AProfile := ReadBpfProfileFromFile(FFilePath);
    AProfile.configJson := jsonText;
    AProfile.lastUpdated := UnixMsNow;

    WriteBpfProfileFile(FFilePath, AProfile);
    result := true;
  except
    on E: Exception do
    begin
      // Nothing was written, so the old BPF and the running core are untouched.
      AError := trim(E.Message);
      result := false;
    end;
  end;

  FFetchLock.Leave;
end;

procedure TConfigUpdater.DoUpdate;
var
  profile: TBpfProfile;
  traffic: TSubscriptionUserInfo;
  err: string;
begin
  if Terminated then
    exit;

  FLastOutcome := cuoUpdating;
  FLastError := '';
  Log('Config update started.');

  if FetchAndStore(err, profile, traffic) then
  begin
    FLastUpdated := profile.lastUpdated;
    FLastOutcome := cuoSuccess;
    Log('Config updated successfully.');
    Notify(profile, traffic, true, '');
  end
  else
  begin
    FLastOutcome := cuoFailed;
    FLastError := err;
    Log('Config update failed. ' + FLastError);
    Notify(Default (TBpfProfile), Default (TSubscriptionUserInfo), false, FLastError);
  end;
end;

function TConfigUpdater.DownloadProfile(out AError: string;
  out ATraffic: TSubscriptionUserInfo): boolean;
var
  profile: TBpfProfile;
begin
  Log('One-shot download started.');
  result := FetchAndStore(AError, profile, ATraffic);
  if result then
    Log('One-shot download finished.')
  else
    Log('One-shot download failed. ' + AError);
end;

procedure TConfigUpdater.Notify(const AProfile: TBpfProfile; const ATraffic: TSubscriptionUserInfo;
  ASuccess: boolean; const AError: string);
var
  handler: TConfigUpdateNotify;
begin
  handler := FOnNotify;
  if not Assigned(handler) then
    exit;

  try
    handler(FFilePath, ASuccess, AError, AProfile, ATraffic);
  except
    // The receiver must never be able to take the worker down.
  end;
end;

procedure TConfigUpdater.Log(const AMessage: string);
begin
  FLogger.Log('ConfigUpdater', AMessage);
end;

end.
