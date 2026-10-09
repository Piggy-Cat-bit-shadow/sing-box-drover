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
  ConfigReader, ConfigUpdater, AppState, SubscriptionManager, SingBoxBpf;

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

  // The completion callback deliberately carries the *file path* rather than the
  // worker instance, so no handler needs a pointer to a thread that is about to
  // free itself. It is an anonymous method type rather than an `of object` method
  // pointer so that callers can capture their own local state (the profile they
  // asked about, for example); an inline anonymous procedure cannot satisfy an
  // `of object` type.
  TProfileUpdateDone = reference to procedure(const AFilePath: string; ASuccess: boolean; const AError: string);

  // One HTTP request, one file.
  //
  // This must be *fully* declared in the interface: TDrover holds a list of these
  // and TProfileUpdateDone is used as a TDrover method parameter. A bare forward
  // declaration ("TProfileUpdateThread = class;") is not enough - the compiler
  // then reports "not yet completely defined" and every use of Finished,
  // FilePath or Terminate on it degrades into an undeclared identifier.
  //
  // FreeOnTerminate is True so the worker owns its own lifetime and nothing can
  // free it while its queued completion callback is still pending. TDrover keeps a
  // non-owning list purely so shutdown can terminate and join workers that are
  // still running.
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
    // Dropping the callback prevents the worker from queueing work that would
    // touch a GUI that is being torn down.
    procedure DetachCallback;
    property Success: boolean read FSuccess;
    property ErrorMessage: string read FError;
    property Traffic: TSubscriptionUserInfo read FTraffic;
    property FilePath: string read FFilePath;
  end;


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
    FUpdateWorkers: TList<TProfileUpdateThread>;
    // Backing state for the published NeedsElevation / CoreState properties. These
    // were previously referenced as if they were fields while being declared as a
    // method (or not at all), which is a compile error.
    FNeedsElevation: boolean;
    FSupervisorState: TCoreState;

    procedure HandleCoreEvent(event: TCoreEvent);
    procedure HandleUpdaterNotify(const AFilePath: string; ASuccess: boolean; const AError: string;
      const AProfile: TBpfProfile; const ATraffic: TSubscriptionUserInfo);
    procedure HandleWorkerTerminated(sender: TObject);
    procedure PostCanClose;
    function TakeUpdateResult(out AResult: TUpdateAttemptResult; out AFilePath: string): boolean;
    function IsWorkerFinished(AWorker: TThread; ATerminateSeen: boolean): boolean;
    function BackgroundWorkersFinished: boolean;
    // Refreshes FSupervisorState from the supervisor so the CoreState property
    // always reflects the core that is actually running.
    procedure SyncSupervisorState;
    procedure RequestShutdownWorkers;
    procedure TryCompleteShutdown;
    // Terminates and joins every one-shot profile worker. Called while shutting
    // down so that no worker can still be running once the GUI is being destroyed.
    procedure StopUpdateWorkers;
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
    // The proxy string this application last applied, '' when it is not the owner
    // of the current Windows proxy setting.
    function AppliedSystemProxyServer: string;

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
    // could not even be scheduled. At most one worker may exist per profile file,
    // so two rapid clicks on the same inactive profile can never write the same
    // BPF concurrently; the second call fails with a "busy" error instead.
    function StartProfileUpdate(const AFilePath: string;
      AOnDone: TProfileUpdateDone; out AError: string): boolean;
    // Frees one-shot workers that have finished. Called from the completion
    // callback once it no longer needs the worker.
    procedure CleanupFinishedUpdateWorkers;
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
    function TryApplyUpdate(out AFilePath: string; out AResult: TUpdateAttemptResult): boolean;
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
  FUpdateWorkers := TList<TProfileUpdateThread>.Create;
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
  SyncSupervisorState;
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

// FSupervisorState is a plain field, published through the CoreState property and
// refreshed by SyncSupervisorState whenever a core event arrives.
procedure TDrover.SyncSupervisorState;
begin
  if Assigned(FSupervisor) then
    FSupervisorState := FSupervisor.state
  else
    FSupervisorState := csStopped;
end;

function TDrover.ResolveConfigPath: string;
begin
  // 1. an explicitly selected profile, when it still exists and decodes
  if FActiveProfilePath <> '' then
  begin
    if TFile.Exists(FActiveProfilePath) then
    begin
      try
        TSubscriptionManager.Load(FActiveProfilePath);
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
  worker: TProfileUpdateThread;
begin
  result := false;
  AError := '';

  if FShutdownRequested then
  begin
    AError := 'Shutting down.';
    exit;
  end;

  // Serialize per file: a worker that is still running for this profile would
  // write the same BPF, so refuse the second request instead of racing it.
  for worker in FUpdateWorkers do
  begin
    if SameText(worker.FilePath, AFilePath) and (not worker.Finished) then
    begin
      AError := 'Update already in progress for this profile.';
      exit;
    end;
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

// The worker list only ever shrinks here, and it is a non-owning list: each worker
// has FreeOnTerminate = True and frees itself. This only drops the list reference.
//
// When the thread finishes, the RTL defers the actual self-free until its queued
// Execute method has run, so by the time a worker is observed as Finished here its
// completion callback has already been dispatched and the object is gone.
procedure TDrover.CleanupFinishedUpdateWorkers;
var
  index: integer;
begin
  for index := FUpdateWorkers.Count - 1 downto 0 do
    if FUpdateWorkers[index].Finished then
      FUpdateWorkers.Delete(index);
end;

// Terminates and joins every outstanding one-shot worker. The wait is bounded
// because TThread.WaitFor has no timeout overload: a worker stuck in a socket
// call must never be able to hang the shutdown path forever. Termination cancels
// the in-flight HTTP request, which is what makes workers return promptly.
procedure TDrover.StopUpdateWorkers;
const
  WORKER_JOIN_TIMEOUT_MS = 5000;
  JOIN_POLL_INTERVAL_MS = 20;
var
  index: integer;
  worker: TProfileUpdateThread;
  startedAt: UInt64;
begin
  for index := 0 to FUpdateWorkers.Count - 1 do
  begin
    worker := FUpdateWorkers[index];
    if Assigned(worker) and (not worker.Finished) then
    begin
      // Drop the callback first: after this point the worker must not queue work
      // that would touch the GUI while it is being torn down.
      worker.DetachCallback;
      worker.Terminate;
    end;
  end;

  // GetTickCount64 cannot wrap, unlike GetTickCount, so elapsed-time arithmetic
  // stays correct no matter how long the machine has been up.
  startedAt := GetTickCount64;
  for index := 0 to FUpdateWorkers.Count - 1 do
  begin
    worker := FUpdateWorkers[index];
    while Assigned(worker) and (not worker.Finished) and
      ((GetTickCount64 - startedAt) < WORKER_JOIN_TIMEOUT_MS) do
      Sleep(JOIN_POLL_INTERVAL_MS);

    if Assigned(worker) and (not worker.Finished) then
      Log('A profile update worker did not stop within the join timeout.');
  end;

  FUpdateWorkers.Clear;
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

function TDrover.TryApplyUpdate(out AFilePath: string; out AResult: TUpdateAttemptResult): boolean;
begin
  result := false;
  AFilePath := '';
  AResult := Default (TUpdateAttemptResult);

  if not TakeUpdateResult(AResult, AFilePath) then
    exit;

  result := true;
  if not AResult.success then
  begin
    NotifyEvent(dekSubscriptionUpdated, '');
    exit;
  end;

  // Traffic metadata belongs to AppState, never to the BPF: the BPF format stays
  // untouched.
  FAppState.SetSubscriptionInfo(TSubscriptionManager.ToStoredPath(AFilePath, currentProcessDir),
    AResult.traffic);

  if not IsActiveProfile(AFilePath) then
  begin
    // An inactive subscription updated: the file changed, the running core must
    // not. This is the guard against "A, B, C all update, core ends up on C".
    Log('Inactive profile updated, runtime untouched: ' + AFilePath);
    NotifyEvent(dekSubscriptionUpdated, '');
    exit;
  end;

  configSource.bpfProfile.lastUpdated := AResult.profile.lastUpdated;
  FPendingProfilePath := AFilePath;
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

  // Keep the published CoreState in step with the core, including for event kinds
  // that are not forwarded to the GUI.
  SyncSupervisorState;

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

// Restores the Windows proxy that was in place before this application changed it.
// SystemProxy refuses to touch a value another tool has written since, so this is
// safe to call even when the user has switched proxy managers while we ran.
function TDrover.DisableSystemProxy: boolean;
begin
  result := SystemProxy.DisableSystemProxy;
end;

// '' when this application is not currently responsible for the Windows proxy.
function TDrover.AppliedSystemProxyServer: string;
begin
  result := SystemProxy.AppliedProxyServer;
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

  // The one-shot profile workers are owned here too: any of them still running
  // must be joined before the GUI can be destroyed, otherwise its completion
  // callback could touch a freed form.
  StopUpdateWorkers;
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


// TProfileUpdateThread is declared in the interface section: TDrover holds a list
// of them and the completion callback is a TDrover method parameter.

// Called while shutting down, before the worker is terminated: after this the
// worker must not queue a callback that would touch a GUI being torn down.
procedure TProfileUpdateThread.DetachCallback;
begin
  FOnDone := nil;
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

  FreeOnTerminate := true;
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
  path: string;
  err: string;
  ok: boolean;
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

  // Copy everything the queued callback needs into locals. Capturing the fields
  // directly would make the closure capture Self, and this thread frees itself on
  // termination, so the callback must not dereference the instance at all.
  path := FFilePath;
  err := FError;
  ok := FSuccess;

  TThread.Queue(nil,
    procedure
    begin
      handler(path, ok, err);
    end);
end;

end.
