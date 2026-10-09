unit ConfigUpdater;

// Single worker thread that owns *all* remote profile updates.
//
// Both the automatic interval and the "更新" menu item drive this one thread, so
// there is never a second HTTP request and never two writers for the same BPF.
// A candidate config is validated before it replaces anything, and nothing is
// written at all when the download or validation fails.
//
// The worker knows nothing about the GUI: it reports results through
// TConfigUpdateNotify, which TDrover marshals back to the main thread.

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs,
  System.Net.HttpClient, System.Net.URLClient, Logger, SingBoxCli, SingBoxConfig;

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
    FRequest: IHTTPRequest;
    FRequestLock: TCriticalSection;
    FPendingLock: TCriticalSection;
    FUpdatePending: integer;
    FLastUpdated: int64;
    FLastOutcome: TConfigUpdateOutcome;
    FLastError: string;
    FRedirectPolicy: THTTPRedirectPolicy;

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
    // ARedirectPolicy defaults to THTTPRedirectPolicy.Always: airport
    // subscription URLs redirect as a rule, and a one-shot worker has nothing
    // to gain from refusing them.
    constructor Create(const AFilePath, ARemotePath: string; AIntervalMinutes: int32;
      ALastUpdated: int64; ASingBoxCli: TSingBoxCli; ALogger: TLogger; const AWorkDir: string;
      ARedirectPolicy: THTTPRedirectPolicy = THTTPRedirectPolicy.Always);
    destructor Destroy; override;

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
  ConfigReader, SingBoxBpf;

const
  INITIAL_DELAY_MS = 60000;
  MIN_INTERVAL_MINUTES = 15;
  MS_PER_MINUTE = 60000;
  CONNECTION_TIMEOUT_MS = 15000;
  SEND_TIMEOUT_MS = 15000;
  RESPONSE_TIMEOUT_MS = 30000;

  // .NET DateTime ticks (100 ns since 0001-01-01) counted at the Unix epoch.
  DOTNET_EPOCH_TICKS = int64(621355968000000000);
  TICKS_PER_MS = int64(10000);
  USERINFO_HEADER = 'Subscription-Userinfo';

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

function DotNetDateToUnix(AValue: string): int64;
var
  ticks: int64;
begin
  result := 0;
  AValue := trim(AValue);
  if AValue = '' then
    exit;

  ticks := StrToInt64Def(AValue, 0);
  if ticks <= DOTNET_EPOCH_TICKS then
    exit;

  result := (ticks - DOTNET_EPOCH_TICKS) div TICKS_PER_MS div 1000;
  if result < 0 then
    result := 0;
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
      AInfo.expire := DotNetDateToUnix(value);
  end;
end;

constructor TConfigUpdater.Create(const AFilePath, ARemotePath: string; AIntervalMinutes: int32;
  ALastUpdated: int64; ASingBoxCli: TSingBoxCli; ALogger: TLogger; const AWorkDir: string;
  ARedirectPolicy: THTTPRedirectPolicy);
begin
  FFilePath := AFilePath;
  FRemotePath := ARemotePath;
  FRedirectPolicy := ARedirectPolicy;
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
  FRequestLock := TCriticalSection.Create;
  FPendingLock := TCriticalSection.Create;

  FreeOnTerminate := false;
  inherited Create(false);
end;

destructor TConfigUpdater.Destroy;
begin
  Terminate;
  FStopEvent.SetEvent;
  FWakeEvent.SetEvent;
  WaitFor;

  FreeAndNil(FStopEvent);
  FreeAndNil(FWakeEvent);
  FreeAndNil(FRequestLock);
  FreeAndNil(FPendingLock);

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

procedure TConfigUpdater.Execute;
var
  handles: array [0 .. 1] of THandle;
  waitResult: TWaitResult;
  due: boolean;
begin
  Log(format('Updater started for "%s" (interval %d min).', [FFilePath, FIntervalMs div MS_PER_MINUTE]));

  handles[0] := FStopEvent.Handle;
  handles[1] := FWakeEvent.Handle;

  if FStopEvent.WaitFor(INITIAL_DELAY_MS) <> wrTimeout then
    exit;

  while not Terminated do
  begin
    waitResult := TWaitResult.Poll(handles, FIntervalMs);

    if Terminated then
      break;

    if waitResult = wrSignaled then
    begin
      if FStopEvent.WaitFor(0) = wrSignaled then
        break;

      due := ConsumePendingUpdate or IntervalElapsed;
      if due then
        DoUpdate;
      continue;
    end;

    // wrTimeout: the interval expired on its own.
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

  try
    http := THTTPClient.Create;
    try
      http.UserAgent := BuildUserAgent;
      http.ConnectionTimeout := CONNECTION_TIMEOUT_MS;
      http.SendTimeout := SEND_TIMEOUT_MS;
      http.ResponseTimeout := RESPONSE_TIMEOUT_MS;
      http.RedirectPolicy := FRedirectPolicy;

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
