unit Drover;

// Thin orchestration layer around CoreSupervisor + ConfigUpdater + profiles.
//
// Rules this unit enforces:
//   * The core always receives the raw config text, byte for byte as read from
//     the file or profile. Nothing here rewrites a sing-box config.
//   * App alive = core alive. There is no start/stop/pause state machine.
//   * Only the *active* profile may influence the running core.
//   * A failed download/validation never touches the BPF, the active profile or
//     the running core.

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.Menus, SystemProxy,
  System.JSON, System.IOUtils, System.Generics.Collections, System.SyncObjs,
  Winapi.ShellAPI, Options,
  CoreSupervisor, Logger, AppElevation, AppArgs, SingBoxConfig, SingBoxCli,
  ConfigReader, ConfigUpdater, AppState, SubscriptionManager;

const
  WM_DROVER_CAN_CLOSE = WM_APP + 501;
  WM_DROVER_UPDATER_EVENT = WM_APP + 503;
  STATE_FILENAME = 'JieJieBox.state.json';
  LEGACY_STATE_FILENAME = 'sing-box-drover.state.json';

  // Default automatic update period for a newly added subscription, in minutes.
  DEFAULT_UPDATE_INTERVAL_MINUTES = 720;

type
  TDroverEventKind = (dekError, dekRunning, dekCoreEvent, dekSubscriptionUpdated);

  TDroverEvent = record
    kind: TDroverEventKind;
    msg: string;
    coreEvent: TCoreEvent;
    profilePath: string;
    profile: TBpfProfile;
  end;

  TDroverEventHandler = procedure(event: TDroverEvent) of object;

  TUpdateAttemptResult = record
    success: boolean;
    error: string;
    profile: TBpfProfile;
    traffic: TSubscriptionUserInfo;
  end;

  TUpdaterEvent = record
    filePath: string;
    result: TUpdateAttemptResult;
  end;

  PUpdaterEvent = ^TUpdaterEvent;

  // One-shot worker used by the manual update entry for a profile that is not the active one.
  // It touches exactly one file and never the running core.
  TProfileUpdateThread = class;
  TProfileUpdateDone = procedure(Sender: TProfileUpdateThread; ASuccess: boolean; const AError: string) of object;

  TDrover = class
  private
    FSupervisor: TCoreSupervisor;
    FConfigUpdater: TConfigUpdater;
    FSingBoxCli: TSingBoxCli;
    FOnEvent: TDroverEventHandler;
    FLogger: TLogger;
    FNotifyHandle: HWND;
    FShutdownRequested: boolean;
    FShutdownCompleted: boolean;
    FSupervisorTerminateSeen: boolean;
    FConfigUpdaterTerminateSeen: boolean;
    FDestroying: boolean;
    FPendingEvents: TList<TDroverEvent>;
    FIsElevated: boolean;
    FPendingConfigText: string;
    FPendingProfilePath: string;
    FSelectors: TConfigSelectors;
    FAppState: TAppState;
    FProfilesDir: string;
    FActiveProfilePath: string;
    FUpdaterResults: TThreadedQueue<TUpdaterEvent>;
    FUpdateWorkers: TObjectList<TProfileUpdateThread>;

    procedure HandleCoreEvent(event: TCoreEvent);
    procedure HandleUpdaterNotify(const AFilePath: string; ASuccess: boolean; const AError: string;
      const AProfile: TBpfProfile; const ATraffic: TSubscriptionUserInfo);
    procedure HandleWorkerTerminated(sender: TObject);
    procedure PostCanClose;
    function TakeUpdateResult(out AResult: TUpdateAttemptResult; out AFilePath: string): boolean;
    function IsWorkerFinished(AWorker: TThread; ATerminateSeen: boolean): boolean;
    function BackgroundWorkersFinished: boolean;
    procedure RequestShutdownWorkers;
    procedure TryCompleteShutdown;
    procedure NotifyEvent(kind: TDroverEventKind; msg: string = ''); overload;
    procedure NotifyEvent(const event: TDroverEvent); overload;
    procedure ForwardCoreEvent(const event: TCoreEvent);
    procedure SetOnEvent(value: TDroverEventHandler);
    procedure FlushPendingEvents;
    procedure DestroyConfigUpdater;
    procedure DestroySupervisor;
    procedure ApplyPersistedSelectors;
    procedure SyncSelectorSnapshot;
    procedure Log(const AMessage: string);
    procedure BuildUpdaterForActiveProfile;
    function IsRemoteAutoUpdateSource: boolean;
    function ResolveConfigPath: string;
    procedure ApplyProfile(const AProfilePath, AConfigText: string);
  public
    configSource: TConfigSource;
    sbConfig: TSingBoxConfig;
    FOptions: TDroverOptions;
    currentProcessDir: string;

    constructor Create(AFlags: TAppFlags);
    destructor Destroy; override;

    procedure ResetSelectors;
    procedure PersistSelectors;
    procedure PersistRuntimeState;
    function EditSelector(selectorIdx, outboundIdx: integer; requestId: NativeInt): boolean;

    function EnableSystemProxy: boolean;
    function DisableSystemProxy: boolean;

    function Shutdown: boolean;

    // Starts (or restarts) the core with the raw config of the active profile.
    // CoreSupervisor.DoStart already stops the old core first, so this doubles
    // as "restart core" and never restarts the GUI.
    procedure RestartCore;

    // Brings the core up with the raw active config. Called by the program after
    // the elevation decision; the constructor deliberately does not start it.
    procedure Start;
    function CanUseTunNow: boolean;
    // True when the config has a tun inbound and we are not elevated yet. The
    // program turns this into one UAC relaunch.
    property NeedsElevation: boolean read FNeedsElevation;
    function CoreVersion: string;

    function ListProfiles: TProfileList;
    function ProfilesDir: string;
    function OpenProfilesDir: boolean;
    function AddSubscription(const AName, AUrl: string; out AFilePath: string): boolean;
    function DeleteSubscription(const AFilePath: string): boolean;
    // Refreshes the active profile through the single long-lived updater.
    procedure UpdateProfileNow(const AFilePath: string);
    // Makes AFilePath the active profile and immediately activates it.
    function SwitchProfile(const AFilePath: string; out AError: string): boolean;
    // Starts a one-shot download for any profile. AError is set when the request
    // could not even be scheduled.
    function StartProfileUpdate(const AFilePath: string;
      AOnDone: TProfileUpdateDone; out AError: string): boolean;
    function ActiveProfilePath: string;
    function IsActiveProfile(const AFilePath: string): boolean;
    function GetSubscriptionInfo(const AProfilePath: string; out AInfo: TSubscriptionUserInfo): boolean;
    function HasActiveRemoteProfile: boolean;
    function ActiveProfileLastUpdated: int64;
    // Rebuilds the update worker for the current active profile (used after the
    // auto-update toggle changed). Never touches the running core.
    procedure RefreshUpdater;
    // Automatic update period of the active profile, in milliseconds (already
    // clamped to the 15 minute minimum).
    function NextIntervalMs: cardinal;

    // Applies a finished update attempt on the main thread.
    //
    //  * failure            -> nothing changed, only an error event is raised
    //  * inactive profile   -> the file was rewritten, the core is left alone
    //  * active profile     -> config is re-parsed and the core restarts once
    //
    // Returns True when a result was consumed; AFilePath then names the profile
    // that was updated. The caller refreshes the tray menu on every event.
    function TryApplyUpdate(const AFilePath: string; out AResult: TUpdateAttemptResult): boolean;
    // Applies a profile whose file changed while it was the active one.
    function ApplyPendingReload: boolean;

    property Options: TDroverOptions read FOptions;
    property OnEvent: TDroverEventHandler read FOnEvent write SetOnEvent;
    property NotifyHandle: HWND read FNotifyHandle write FNotifyHandle;
    property Selectors: TConfigSelectors read FSelectors;
    property CoreState: TCoreState read FSupervisorState;
  end;

implementation

uses
  System.StrUtils, System.DateUtils;

constructor TDrover.Create(AFlags: TAppFlags);
var
  statePath, legacyStatePath, configPath, corePath, profilesDir, storedActive: string;
begin
  FPendingEvents := TList<TDroverEvent>.Create;
  FUpdaterResults := TThreadedQueue<TUpdaterEvent>.Create(64, 1000, 1000);
  FUpdateWorkers := TObjectList<TProfileUpdateThread>.Create(false);
  FConfigUpdater := nil;
  FActiveProfilePath := '';
  FPendingConfigText := '';
  FPendingProfilePath := '';

  currentProcessDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));

  FOptions := TDroverOptions.Load(currentProcessDir + OPTIONS_FILENAME);

  // A read-only install directory must not stop the GUI from running.
  FLogger := TLogger.Create(FOptions.logFile);

  FIsElevated := AppElevation.IsProcessElevated;

  statePath := currentProcessDir + STATE_FILENAME;
  if not TFile.Exists(statePath) then
  begin
    legacyStatePath := currentProcessDir + LEGACY_STATE_FILENAME;
    if TFile.Exists(legacyStatePath) then
      statePath := legacyStatePath;
  end;
  FAppState := TAppState.Create(statePath);
  try
    FAppState.Persist;
  except
  end;

  profilesDir := TSubscriptionManager.EnsureProfilesDir(currentProcessDir);
  FProfilesDir := profilesDir;

  storedActive := FAppState.ActiveProfilePath;
  if storedActive <> '' then
    FActiveProfilePath := TSubscriptionManager.FromStoredPath(storedActive, currentProcessDir);

  configPath := ResolveConfigPath;

  configSource := ConfigReader.ReadConfigSource(configPath);
  sbConfig := ConfigReader.ReadSingBoxConfig(configSource.jsonText);
  FSelectors := sbConfig.selectors;

  if (afRestart in AFlags) or FOptions.selectorPersist then
    ApplyPersistedSelectors;

  corePath := FOptions.sbDir + 'sing-box.exe';
  if not TFile.Exists(corePath) then
    raise Exception.Create('sing-box executable not found: ' + corePath);

  FSingBoxCli := TSingBoxCli.Create(corePath, FLogger);

  // clash_api comes from the config. When it is absent the API client stays
  // unconfigured and the selector menu simply will not appear.
  FSupervisor := TCoreSupervisor.Create(corePath, FLogger, sbConfig.clashApi);
  FSupervisor.OnEvent := HandleCoreEvent;
  FSupervisor.OnTerminate := HandleWorkerTerminated;

  FNeedsElevation := sbConfig.hasTunInbound and (not FIsElevated);
end;

procedure TDrover.Start;
begin
  RestartCore;
  BuildUpdaterForActiveProfile;
end;

destructor TDrover.Destroy;
begin
  FDestroying := true;

  DestroyConfigUpdater;
  DestroySupervisor;

  FreeAndNil(FSingBoxCli);
  FreeAndNil(FAppState);
  FreeAndNil(FUpdateWorkers);
  if Assigned(FUpdaterResults) then
    FUpdaterResults.DoShutDown;
  FreeAndNil(FUpdaterResults);
  FreeAndNil(FPendingEvents);
  FreeAndNil(FLogger);

  inherited;
end;

function TDrover.FSupervisorState: TCoreState;
begin
  if Assigned(FSupervisor) then
    result := FSupervisor.state
  else
    result := csStopped;
end;

function TDrover.ResolveConfigPath: string;
begin
  // 1. an explicitly selected profile, when it still exists and decodes
  if FActiveProfilePath <> '' then
  begin
    if TFile.Exists(FActiveProfilePath) then
    begin
      try
        SubscriptionManager.Load(FActiveProfilePath);
        exit(FActiveProfilePath);
      except
        Log('Active profile is unreadable, falling back to the config file: ' + FActiveProfilePath);
      end;
    end
    else
      Log('Active profile is missing, falling back to the config file: ' + FActiveProfilePath);
  end;

  // 2. legacy / plain config file
  FActiveProfilePath := '';
  result := FOptions.sbConfigFile;
end;

procedure TDrover.ApplyProfile(const AProfilePath, AConfigText: string);
begin
  configSource.filePath := AProfilePath;
  configSource.format := csfBpf;
  configSource.bpfProfile := ReadBpfProfileFromFile(AProfilePath);
  configSource.jsonText := AConfigText;

  sbConfig := ConfigReader.ReadSingBoxConfig(configSource.jsonText);
  FSelectors := sbConfig.selectors;

  if FOptions.selectorPersist then
    ApplyPersistedSelectors;

  SyncSelectorSnapshot;

  FActiveProfilePath := AProfilePath;
  try
    FAppState.ActiveProfilePath := TSubscriptionManager.ToStoredPath(AProfilePath, currentProcessDir);
    FAppState.Persist;
  except
    on E: Exception do
      Log('Failed to persist active profile: ' + E.Message);
  end;

  // The core API address/secret can change with the config.
  FSupervisor.SetClashApiConfig(sbConfig.clashApi);
end;

procedure TDrover.SyncSelectorSnapshot;
var
  values: TDictionary<string, string>;
  selector: TConfigSelector;
begin
  values := TDictionary<string, string>.Create;
  try
    for selector in FSelectors do
      if (selector.defaultIndex >= 0) and (selector.defaultIndex < Length(selector.outbounds)) then
        values.AddOrSetValue(selector.name, selector.outbounds[selector.defaultIndex]);

    FAppState.SyncSelectors(values, []);
  except
    on E: Exception do
      Log('Failed to sync selector state. ' + E.Message);
  end;
  values.Free;
end;

procedure TDrover.RestartCore;
begin
  FSupervisor.RequestStart(configSource.jsonText);
end;

function TDrover.CanUseTunNow: boolean;
begin
  result := sbConfig.hasTunInbound and FIsElevated;
end;

function TDrover.CoreVersion: string;
begin
  if Assigned(FSingBoxCli) then
    result := FSingBoxCli.GetVersion
  else
    result := '';
end;

function TDrover.ProfilesDir: string;
begin
  if FProfilesDir = '' then
    FProfilesDir := TSubscriptionManager.EnsureProfilesDir(currentProcessDir);
  result := FProfilesDir;
end;

function TDrover.ListProfiles: TProfileList;
begin
  result := TSubscriptionManager.List(ProfilesDir);
end;

function TDrover.OpenProfilesDir: boolean;
var
  dir: string;
begin
  result := false;
  dir := ProfilesDir;
  if dir = '' then
    exit;

  try
    if not TDirectory.Exists(dir) then
      TDirectory.CreateDirectory(dir);
  except
  end;

  result := ShellExecute(0, 'open', PChar(dir), nil, nil, SW_SHOWNORMAL) > 32;
end;

function TDrover.AddSubscription(const AName, AUrl: string; out AFilePath: string): boolean;
var
  profile: TBpfProfile;
  target: string;
begin
  result := false;
  AFilePath := '';

  target := TSubscriptionManager.BuildProfilePath(ProfilesDir, AName);
  if target = '' then
    exit;

  // The actual config is fetched by the updater; the placeholder exists so the
  // profile shows up (and can be deleted) immediately.
  profile := CreateRemoteBpfProfile('', AName, AUrl, true, DEFAULT_UPDATE_INTERVAL_MINUTES, 0);

  if not TSubscriptionManager.Write(target, profile) then
    exit;

  AFilePath := target;
  result := true;
end;

function TDrover.DeleteSubscription(const AFilePath: string): boolean;
begin
  result := false;

  // An active profile must never be deleted: switch away first.
  if IsActiveProfile(AFilePath) then
  begin
    Log('Refusing to delete the active profile.');
    exit;
  end;

  result := TSubscriptionManager.Delete(AFilePath);
end;

function TDrover.IsActiveProfile(const AFilePath: string): boolean;
begin
  result := TSubscriptionManager.SamePath(AFilePath, FActiveProfilePath);
end;

function TDrover.ActiveProfilePath: string;
begin
  result := FActiveProfilePath;
end;

function TDrover.GetSubscriptionInfo(const AProfilePath: string; out AInfo: TSubscriptionUserInfo): boolean;
var
  stored: string;
begin
  stored := TSubscriptionManager.ToStoredPath(AProfilePath, currentProcessDir);
  result := FAppState.GetSubscriptionInfo(stored, AInfo);
end;

function TDrover.ActiveProfileLastUpdated: int64;
begin
  result := 0;
  if configSource.isBpf then
    result := configSource.bpfProfile.lastUpdated;
end;

function TDrover.HasActiveRemoteProfile: boolean;
begin
  result := IsRemoteAutoUpdateSource;
end;

function TDrover.IsRemoteAutoUpdateSource: boolean;
begin
  result := configSource.isBpf and configSource.bpfProfile.isRemote and
    (trim(configSource.bpfProfile.remotePath) <> '');
end;

// Activates AFilePath and restarts the core once. AError is filled and nothing
// changes when the file is missing, empty or does not parse.
function TDrover.SwitchProfile(const AFilePath: string; out AError: string): boolean;
var
  text: string;
begin
  result := false;
  AError := '';

  if not TFile.Exists(AFilePath) then
  begin
    AError := 'Profile file not found.';
    exit;
  end;

  try
    text := ConfigReader.ReadConfigSource(AFilePath).jsonText;
    if trim(text) = '' then
    begin
      AError := 'Profile has no configuration yet.';
      exit;
    end;
    // Validate before it can reach the core.
    ConfigReader.ReadSingBoxConfig(text);
  except
    on E: Exception do
    begin
      AError := E.Message;
      exit;
    end;
  end;

  ApplyProfile(AFilePath, text);
  BuildUpdaterForActiveProfile;

  // A single RequestStart: the supervisor stops the old core and starts the new
  // one, so a profile switch results in exactly one restart.
  RestartCore;

  NotifyEvent(dekSubscriptionUpdated, '');
  result := true;
end;

procedure TDrover.UpdateProfileNow(const AFilePath: string);
var
  remotePath: string;
begin
  if not TSubscriptionManager.SamePath(AFilePath, FActiveProfilePath) then
  begin
    // Inactive profiles are handled by StartProfileUpdate instead.
    Log('Manual update requested for an inactive profile; use StartProfileUpdate.');
    exit;
  end;

  if not Assigned(FConfigUpdater) then
    exit;

  remotePath := configSource.bpfProfile.remotePath;
  if trim(remotePath) = '' then
    exit;

  Log('Manual update requested.');
  FConfigUpdater.UpdateNow;
end;

function TDrover.StartProfileUpdate(const AFilePath: string;
  AOnDone: TProfileUpdateDone; out AError: string): boolean;
var
  profile: TSubscriptionProfile;
  thread: TProfileUpdateThread;
begin
  result := false;
  AError := '';

  if FShutdownRequested then
  begin
    AError := 'Shutting down.';
    exit;
  end;

  try
    profile := TSubscriptionManager.Load(AFilePath);
  except
    on E: Exception do
    begin
      AError := E.Message;
      exit;
    end;
  end;

  if trim(profile.remotePath) = '' then
  begin
    AError := 'Profile has no remote URL.';
    exit;
  end;

  thread := TProfileUpdateThread.Create(AFilePath, profile.remotePath,
    profile.autoUpdateInterval, profile.lastUpdated, FSingBoxCli, FLogger,
    IncludeTrailingPathDelimiter(FOptions.sbDir), AOnDone);
  FUpdateWorkers.Add(thread);
  result := true;
end;

procedure TDrover.RefreshUpdater;
begin
  BuildUpdaterForActiveProfile;
end;

procedure TDrover.BuildUpdaterForActiveProfile;
var
  profile: TBpfProfile;
begin
  DestroyConfigUpdater;

  if not IsRemoteAutoUpdateSource then
    exit;

  profile := configSource.bpfProfile;

  FConfigUpdaterTerminateSeen := false;
  FConfigUpdater := TConfigUpdater.Create(
    configSource.filePath,
    profile.remotePath,
    profile.autoUpdateInterval,
    profile.lastUpdated,
    FSingBoxCli,
    FLogger,
    IncludeTrailingPathDelimiter(FOptions.sbDir));
  FConfigUpdater.OnNotify := HandleUpdaterNotify;
  FConfigUpdater.OnTerminate := HandleWorkerTerminated;
end;

function TDrover.TakeUpdateResult(out AResult: TUpdateAttemptResult; out AFilePath: string): boolean;
var
  item: TUpdaterEvent;
begin
  AResult := Default (TUpdateAttemptResult);
  AFilePath := '';

  if FUpdaterResults.PopItem(item) <> wrSignaled then
    exit;

  AResult := item.result;
  AFilePath := item.filePath;
  result := true;
end;

function TDrover.TryApplyUpdate(const AFilePath: string; out AResult: TUpdateAttemptResult): boolean;
var
  storedPath: string;
begin
  result := false;
  AResult := Default (TUpdateAttemptResult);

  if not TakeUpdateResult(AResult, storedPath) then
    exit;

  AFilePath := storedPath;
  result := true;

  if not AResult.success then
  begin
    NotifyEvent(dekSubscriptionUpdated, '');
    exit;
  end;

  // Traffic metadata belongs to AppState, never to the BPF: the BPF format stays
  // untouched.
  FAppState.SetSubscriptionInfo(TSubscriptionManager.ToStoredPath(storedPath, currentProcessDir),
    AResult.traffic);

  if not IsActiveProfile(storedPath) then
  begin
    // An inactive subscription updated: the file changed, the running core must
    // not. This is the guard against "A, B, C all update, core ends up on C".
    Log('Inactive profile updated, runtime untouched: ' + storedPath);
    NotifyEvent(dekSubscriptionUpdated, '');
    exit;
  end;

  configSource.bpfProfile.lastUpdated := AResult.profile.lastUpdated;
  FPendingProfilePath := storedPath;
  FPendingConfigText := AResult.profile.configJson;

  if not ApplyPendingReload then
    NotifyEvent(dekSubscriptionUpdated, '');
end;

function TDrover.ApplyPendingReload: boolean;
var
  fresh: TConfigSource;
begin
  result := false;

  if FPendingConfigText = '' then
    exit;

  if not IsActiveProfile(FPendingProfilePath) then
  begin
    FPendingConfigText := '';
    FPendingProfilePath := '';
    exit;
  end;

  try
    fresh := ConfigReader.ReadConfigSource(FPendingProfilePath);
    ApplyProfile(FPendingProfilePath, fresh.jsonText);
  except
    on E: Exception do
    begin
      Log('Failed to apply the updated active profile: ' + E.Message);
      FPendingConfigText := '';
      FPendingProfilePath := '';
      exit;
    end;
  end;

  FPendingConfigText := '';
  FPendingProfilePath := '';

  // Only the active profile reaching this point may restart the core.
  RestartCore;
  NotifyEvent(dekSubscriptionUpdated, '');
  result := true;
end;

function TDrover.NextIntervalMs: cardinal;
var
  minutes: int64;
begin
  minutes := DEFAULT_UPDATE_INTERVAL_MINUTES;
  if configSource.isBpf and (configSource.bpfProfile.autoUpdateInterval > 0) then
    minutes := configSource.bpfProfile.autoUpdateInterval;

  if minutes < 15 then
    minutes := 15;

  result := cardinal(minutes * 60000);
end;

procedure TDrover.HandleUpdaterNotify(const AFilePath: string; ASuccess: boolean; const AError: string;
  const AProfile: TBpfProfile; const ATraffic: TSubscriptionUserInfo);
var
  item: TUpdaterEvent;
begin
  if FDestroying then
    exit;

  item := Default (TUpdaterEvent);
  item.filePath := AFilePath;
  item.result.success := ASuccess;
  item.result.error := AError;
  item.result.profile := AProfile;
  item.result.traffic := ATraffic;

  // The worker thread only queues; the main thread decides what to do.
  FUpdaterResults.PushItem(item);

  NotifyEvent(dekSubscriptionUpdated, '');
end;

procedure TDrover.SetOnEvent(value: TDroverEventHandler);
begin
  FOnEvent := value;
  if Assigned(FOnEvent) then
    FlushPendingEvents;
end;

procedure TDrover.NotifyEvent(kind: TDroverEventKind; msg: string = '');
var
  ev: TDroverEvent;
begin
  ev := Default (TDroverEvent);
  ev.kind := kind;
  ev.msg := msg;

  NotifyEvent(ev);
end;

procedure TDrover.NotifyEvent(const event: TDroverEvent);
var
  handler: TDroverEventHandler;
  local: TDroverEvent;
begin
  if FDestroying then
    exit;

  handler := FOnEvent;
  if not Assigned(handler) then
  begin
    FPendingEvents.Add(event);
    exit;
  end;

  if GetCurrentThreadId = MainThreadID then
  begin
    handler(event);
    exit;
  end;

  local := event;
  TThread.Queue(nil,
    procedure
    begin
      if FDestroying then
        exit;
      if Assigned(FOnEvent) then
        FOnEvent(local);
    end);
end;

procedure TDrover.ForwardCoreEvent(const event: TCoreEvent);
var
  ev: TDroverEvent;
begin
  ev := Default (TDroverEvent);
  ev.kind := dekCoreEvent;
  ev.coreEvent := event;
  NotifyEvent(ev);
end;

procedure TDrover.FlushPendingEvents;
var
  ev: TDroverEvent;
begin
  for ev in FPendingEvents do
    FOnEvent(ev);
  FPendingEvents.Clear;
end;

procedure TDrover.DestroyConfigUpdater;
begin
  if not Assigned(FConfigUpdater) then
    exit;

  FConfigUpdater.OnNotify := nil;
  FConfigUpdater.OnTerminate := nil;

  if not FConfigUpdater.Finished then
  begin
    FConfigUpdater.Terminate;
    FConfigUpdater.WaitFor;
  end;

  FreeAndNil(FConfigUpdater);
  FConfigUpdaterTerminateSeen := false;
end;

procedure TDrover.DestroySupervisor;
begin
  if not Assigned(FSupervisor) then
    exit;

  FSupervisor.OnEvent := nil;
  FSupervisor.OnTerminate := nil;

  if not FSupervisor.Finished then
  begin
    FSupervisor.Terminate;
    TThread.RemoveQueuedEvents(FSupervisor);
    FSupervisor.WaitFor;
    TThread.RemoveQueuedEvents(FSupervisor);
  end;

  FreeAndNil(FSupervisor);
end;

procedure TDrover.HandleCoreEvent(event: TCoreEvent);
begin
  if FDestroying or FShutdownRequested then
    exit;

  case event.kind of
    cekState:
      begin
        case event.state of
          csRunning:
            NotifyEvent(dekRunning, '');
          csFailed:
            NotifyEvent(dekError, event.msg);
        end;
      end;

    cekError:
      NotifyEvent(dekError, event.msg);

    cekApiReady:
      ResetSelectors;

    cekSelectorDone:
      ForwardCoreEvent(event);
  end;
end;

procedure TDrover.HandleWorkerTerminated(sender: TObject);
begin
  if sender = FSupervisor then
    FSupervisorTerminateSeen := true
  else if sender = FConfigUpdater then
    FConfigUpdaterTerminateSeen := true;

  if FDestroying or (not FShutdownRequested) or FShutdownCompleted then
    exit;

  TryCompleteShutdown;
  if FShutdownCompleted then
    PostCanClose;
end;

procedure TDrover.ApplyPersistedSelectors;
var
  selectorI, outboundI: integer;
  selector: ^TConfigSelector;
  savedValue: string;
begin
  for selectorI := low(FSelectors) to high(FSelectors) do
  begin
    selector := @FSelectors[selectorI];
    if not FAppState.GetSelector(selector.name, savedValue) then
      continue;
    for outboundI := low(selector.outbounds) to high(selector.outbounds) do
    begin
      if selector.outbounds[outboundI] = savedValue then
      begin
        selector.defaultIndex := outboundI;
        break;
      end;
    end;
  end;
end;

procedure TDrover.ResetSelectors;
var
  selector: TConfigSelector;
  task: TSelectorTask;
  tasks: TSelectorTasks;
begin
  SetLength(tasks, 0);
  task := Default (TSelectorTask);

  for selector in FSelectors do
  begin
    if (selector.defaultIndex >= low(selector.outbounds)) and
      (selector.defaultIndex <= high(selector.outbounds)) then
    begin
      task.name := selector.name;
      task.value := selector.outbounds[selector.defaultIndex];
      SetLength(tasks, Length(tasks) + 1);
      tasks[High(tasks)] := task;
    end;
  end;

  if Length(tasks) < 1 then
    exit;

  FSupervisor.RequestSetSelectors(tasks, 0);
end;

procedure TDrover.PersistSelectors;
var
  values: TDictionary<string, string>;
  scope: TArray<string>;
  i, idx: integer;
  selector: ^TConfigSelector;
begin
  values := TDictionary<string, string>.Create;
  try
    SetLength(scope, length(FSelectors));
    for i := low(FSelectors) to high(FSelectors) do
    begin
      selector := @FSelectors[i];
      scope[i] := selector.name;
      idx := selector.defaultIndex;
      if (idx >= low(selector.outbounds)) and (idx <= high(selector.outbounds)) then
        values.AddOrSetValue(selector.name, selector.outbounds[idx]);
    end;

    try
      FAppState.SyncSelectors(values, scope);
    except
      on E: Exception do
        Log(trim(format('Failed to persist selector state. %s', [E.Message])));
    end;
  finally
    values.Free;
  end;
end;

procedure TDrover.PersistRuntimeState;
begin
  PersistSelectors;
end;

function TDrover.EditSelector(selectorIdx, outboundIdx: integer; requestId: NativeInt): boolean;
var
  selector: TConfigSelector;
  task: TSelectorTask;
begin
  result := false;

  if (selectorIdx < low(FSelectors)) or (selectorIdx > high(FSelectors)) then
    exit;

  selector := FSelectors[selectorIdx];
  if (outboundIdx < low(selector.outbounds)) or (outboundIdx > high(selector.outbounds)) then
    exit;

  FSelectors[selectorIdx].defaultIndex := outboundIdx;
  PersistSelectors;

  task.name := selector.name;
  task.value := selector.outbounds[outboundIdx];

  result := FSupervisor.RequestSetSelectors([task], requestId);
end;

function TDrover.EnableSystemProxy: boolean;
begin
  result := SystemProxy.EnableSystemProxy(sbConfig.proxyHost, sbConfig.proxyPort);
end;

function TDrover.DisableSystemProxy: boolean;
begin
  result := SystemProxy.DisableSystemProxy;
end;

function TDrover.Shutdown: boolean;
begin
  if FShutdownCompleted then
    exit(true);

  if not FShutdownRequested then
  begin
    FShutdownRequested := true;
    RequestShutdownWorkers;
  end;

  TryCompleteShutdown;
  result := FShutdownCompleted;
end;

procedure TDrover.TryCompleteShutdown;
begin
  if FShutdownCompleted or (not BackgroundWorkersFinished) then
    exit;

  FShutdownCompleted := true;
  if Assigned(FLogger) then
    FLogger.Close;
end;

function TDrover.IsWorkerFinished(AWorker: TThread; ATerminateSeen: boolean): boolean;
begin
  result := (not Assigned(AWorker)) or ATerminateSeen or AWorker.Finished;
end;

function TDrover.BackgroundWorkersFinished: boolean;
begin
  result := IsWorkerFinished(FSupervisor, FSupervisorTerminateSeen) and
    IsWorkerFinished(FConfigUpdater, FConfigUpdaterTerminateSeen);
end;

procedure TDrover.RequestShutdownWorkers;
begin
  if Assigned(FConfigUpdater) and not FConfigUpdater.Finished then
  begin
    FConfigUpdater.OnNotify := nil;
    FConfigUpdater.Terminate;
  end;

  if Assigned(FSupervisor) and not FSupervisor.Finished then
  begin
    FSupervisor.OnEvent := nil;
    FSupervisor.Terminate;
    TThread.RemoveQueuedEvents(FSupervisor);
  end;
end;

procedure TDrover.PostCanClose;
begin
  if (FNotifyHandle <> 0) and IsWindow(FNotifyHandle) then
    PostMessage(FNotifyHandle, WM_DROVER_CAN_CLOSE, 0, 0);
end;

procedure TDrover.Log(const AMessage: string);
begin
  FLogger.Log('Drover', AMessage);
end;


type
  // One HTTP request, one file. The owner keeps the reference in a list and
  // frees it only after the download finished and the queued callback has run.
  TProfileUpdateThread = class(TThread)
  private
    FUpdater: TConfigUpdater;
    FFilePath: string;
    FOnDone: TProfileUpdateDone;
    FSuccess: boolean;
    FError: string;
    FTraffic: TSubscriptionUserInfo;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFilePath, ARemotePath: string; AIntervalMinutes: int32;
      ALastUpdated: int64; ASingBoxCli: TSingBoxCli; ALogger: TLogger; const AWorkDir: string;
      AOnDone: TProfileUpdateDone);
    destructor Destroy; override;
    property Success: boolean read FSuccess;
    property ErrorMessage: string read FError;
    property Traffic: TSubscriptionUserInfo read FTraffic;
    property FilePath: string read FFilePath;
  end;

constructor TProfileUpdateThread.Create(const AFilePath, ARemotePath: string;
  AIntervalMinutes: int32; ALastUpdated: int64; ASingBoxCli: TSingBoxCli;
  ALogger: TLogger; const AWorkDir: string; AOnDone: TProfileUpdateDone);
begin
  FFilePath := AFilePath;
  FOnDone := AOnDone;
  FSuccess := false;
  FError := '';

  FUpdater := TConfigUpdater.Create(AFilePath, ARemotePath, AIntervalMinutes,
    ALastUpdated, ASingBoxCli, ALogger, AWorkDir);

  FreeOnTerminate := false;
  inherited Create(false);
end;

destructor TProfileUpdateThread.Destroy;
begin
  FreeAndNil(FUpdater);
  inherited;
end;

procedure TProfileUpdateThread.Execute;
var
  handler: TProfileUpdateDone;
begin
  try
    FSuccess := FUpdater.DownloadProfile(FError, FTraffic);
  except
    on E: Exception do
    begin
      FSuccess := false;
      FError := trim(E.Message);
    end;
  end;

  handler := FOnDone;
  if not Assigned(handler) then
    exit;

  TThread.Queue(nil,
    procedure
    begin
      handler(self, FSuccess, FError);
    end);
end;

end.
