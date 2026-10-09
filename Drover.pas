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

  // One-shot worker for a profile that is not the active one.
  //
  // Ownership: TDrover owns these objects and destroys each one exactly once, from
  // the main thread, after its completion callback has run. FreeOnTerminate is
  // therefore False - the earlier design let the thread free itself while TDrover
  // still held its address in a non-owning list, so reading .Finished or calling
  // Terminate on a finished entry could touch reclaimed memory.
  TProfileUpdateThread = class(TThread)
  private
    FUpdater: TConfigUpdater;
    FFilePath: string;
    FOnDone: TProfileUpdateDone;
    FSuccess: boolean;
    FError: string;
    FTraffic: TSubscriptionUserInfo;
    // Written by this thread, read by the main thread only after Finished.
    FCallbackQueued: boolean;
    FCancelled: boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFilePath, ARemotePath: string; AIntervalMinutes: int32;
      ALastUpdated: int64; ASingBoxCli: TSingBoxCli; ALogger: TLogger; const AWorkDir: string;
      AOnDone: TProfileUpdateDone);
    destructor Destroy; override;
    // Main thread only. Makes the worker finish without queueing a callback, so the
    // GUI can never be touched after it starts tearing down. Cancels the in-flight
    // HTTP request as well, which is what actually makes the worker return promptly.
    procedure CancelAndDetach;
    property CallbackQueued: boolean read FCallbackQueued;
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
    // Owning list: TDrover destroys each one-shot worker exactly once. Only ever
    // mutated on the main thread (StartProfileUpdate, the completion callback, and
    // shutdown), so no locking is required.
    FUpdateWorkers: TObjectList<TProfileUpdateThread>;
    // Backing state for the published NeedsElevation / CoreState properties. These
    // were previously referenced as if they were fields while being declared as a
    // method (or not at all), which is a compile error.
    FNeedsElevation: boolean;
    FSupervisorState: TCoreState;
    // Set once WM_DROVER_CAN_CLOSE has been posted, so the worker Terminate
    // callback and the GUI fallback poll cannot both queue a WM_CLOSE.
    FCanClosePosted: boolean;

    procedure HandleCoreEvent(event: TCoreEvent);
    procedure HandleUpdaterNotify(const AFilePath: string; ASuccess: boolean; const AError: string;
      const AProfile: TBpfProfile; const ATraffic: TSubscriptionUserInfo);
    procedure HandleWorkerTerminated(sender: TObject);
    // Posted at most once per process.
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

    // Idempotent. True only once every background worker is gone and the logger is
    // closed; the GUI waits for PollShutdown or WM_DROVER_CAN_CLOSE rather than
    // closing on the first call.
    function Shutdown: boolean;

    // Re-evaluates shutdown progress, posts WM_DROVER_CAN_CLOSE exactly once on the
    // transition to complete, and returns whether shutdown has finished. Safe to
    // call repeatedly; the GUI uses it as a bounded fallback poll so a lost
    // OnTerminate notification can never leave the process resident.
    function PollShutdown: boolean;
    function ShutdownComplete: boolean;

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
  FUpdateWorkers := TObjectList<TProfileUpdateThread>.Create(true);
  FConfigUpdater := nil;
  FActiveProfilePath := '';
  FPendingConfigText := '';
  FPendingProfilePath := '';
  FShutdownRequested := false;
  FShutdownCompleted := false;
  FSupervisorTerminateSeen := false;
  FConfigUpdaterTerminateSeen := false;
  FCanClosePosted := false;
  FDestroying := false;

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

// Removes workers that have finished, destroying each exactly once.
//
// Main thread only, and safe by construction: a worker is only ever freed here
// after its completion callback has already run (the callback calls this), and
// Finished is read on an object TDrover still owns because FreeOnTerminate is
// False. The previous design freed the thread from inside itself while TDrover kept
// its address in a non-owning list, so every read of .Finished here could have hit
// reclaimed memory.
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
// call must never be able to hang the shutdown path forever. CancelAndDetach
// cancels the in-flight HTTP request first, which is what makes workers return.
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
      worker.CancelAndDetach;
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

// Reached through TThread.OnTerminate, which the RTL delivers by queueing a method
// call to the main thread. This is therefore *one* signal among several and must
// never be the only way shutdown can finish - see TDrover.PollShutdown.
procedure TDrover.HandleWorkerTerminated(sender: TObject);
begin
  if sender = FSupervisor then
    FSupervisorTerminateSeen := true
  else if sender = FConfigUpdater then
    FConfigUpdaterTerminateSeen := true;

  if FDestroying or (not FShutdownRequested) or FShutdownCompleted then
    exit;

  PollShutdown;
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

// Idempotent: the first call owns the shutdown decision, later calls only report
// progress. Returns True once everything has been torn down, which is normally
// False on the first call because the workers need a moment to stop - the GUI then
// waits for PollShutdown/WM_DROVER_CAN_CLOSE instead of closing immediately.
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

// Advances the shutdown state machine and reports whether everything is torn down.
//
// This is deliberately callable from any of three places - the initial close
// request, the worker Terminate callback, and the GUI's fallback poll - because
// completion must never depend on a single notification arriving. TThread.OnTerminate
// is delivered by queueing a method call to the main thread, so it is only *one*
// possible signal and can legitimately be missed.
procedure TDrover.TryCompleteShutdown;
begin
  if FShutdownCompleted then
    exit;

  if not BackgroundWorkersFinished then
    exit;

  FShutdownCompleted := true;
  Log('Shutdown complete: all background workers finished.');

  if Assigned(FLogger) then
    FLogger.Close;
end;

function TDrover.IsWorkerFinished(AWorker: TThread; ATerminateSeen: boolean): boolean;
begin
  // AWorker.Finished is the authoritative signal. OnTerminate is only a hint used
  // to satisfy the unit's existing bookkeeping; the state machine must not require
  // it, because the corresponding queued call can be removed or never delivered.
  result := (not Assigned(AWorker)) or ATerminateSeen or AWorker.Finished;
end;

function TDrover.BackgroundWorkersFinished: boolean;
begin
  result := IsWorkerFinished(FSupervisor, FSupervisorTerminateSeen) and
    IsWorkerFinished(FConfigUpdater, FConfigUpdaterTerminateSeen);
end;

procedure TDrover.RequestShutdownWorkers;
begin
  Log('Shutdown requested: terminating background workers.');

  if Assigned(FConfigUpdater) and not FConfigUpdater.Finished then
  begin
    FConfigUpdater.OnNotify := nil;
    FConfigUpdater.OnTerminate := nil;
    FConfigUpdater.Terminate;
  end;

  if Assigned(FSupervisor) and not FSupervisor.Finished then
  begin
    FSupervisor.OnEvent := nil;
    FSupervisor.OnTerminate := nil;
    FSupervisor.Terminate;
    // NOTE: TThread.RemoveQueuedEvents(FSupervisor) used to be called here. That
    // was the P0 defect: it discarded the queued OnTerminate method call, which was
    // the only route to PostCanClose, so the window was never told it could close
    // and the process stayed resident forever with every thread idle. Completion is
    // now signal-independent, so there is nothing to force-remove.
  end;

  // The one-shot profile workers are owned here too: any of them still running
  // must be joined before the GUI can be destroyed, otherwise its completion
  // callback could touch a freed form.
  StopUpdateWorkers;
end;

// True once every worker is gone and the logger has been closed.
function TDrover.ShutdownComplete: boolean;
begin
  result := FShutdownCompleted;
end;

// Re-evaluates shutdown progress and, on the transition to complete, tells the GUI
// exactly once that the window may close. Safe to call repeatedly.
function TDrover.PollShutdown: boolean;
begin
  if FShutdownRequested then
  begin
    TryCompleteShutdown;
    if FShutdownCompleted then
      PostCanClose;
  end;

  result := FShutdownCompleted;
end;

// Posted at most once. Without the guard, the worker Terminate callback and the
// GUI's fallback poll could both fire and queue two WM_CLOSE messages.
procedure TDrover.PostCanClose;
begin
  if FCanClosePosted then
    exit;

  if (FNotifyHandle = 0) or (not IsWindow(FNotifyHandle)) then
    exit;

  FCanClosePosted := true;
  Log('Posting WM_DROVER_CAN_CLOSE.');

  if not PostMessage(FNotifyHandle, WM_DROVER_CAN_CLOSE, 0, 0) then
    Log('PostMessage(WM_DROVER_CAN_CLOSE) failed; the GUI fallback poll will recover.');
end;

procedure TDrover.Log(const AMessage: string);
begin
  FLogger.Log('Drover', AMessage);
end;


// TProfileUpdateThread is declared in the interface section: TDrover holds a list
// of them and the completion callback is a TDrover method parameter.

// Main thread only. Marks the worker as cancelled and drops its callback so it can
// never touch the GUI, then cancels the in-flight HTTP request.
//
// The updater is put into one-shot mode at construction, so there is no sibling
// scheduling loop to stop here; TConfigUpdater.Destroy performs the join.
procedure TProfileUpdateThread.CancelAndDetach;
begin
  FCancelled := true;
  FOnDone := nil;
  Terminate;
end;

constructor TProfileUpdateThread.Create(const AFilePath, ARemotePath: string;
  AIntervalMinutes: int32; ALastUpdated: int64; ASingBoxCli: TSingBoxCli;
  ALogger: TLogger; const AWorkDir: string; AOnDone: TProfileUpdateDone);
begin
  FFilePath := AFilePath;
  FOnDone := AOnDone;
  FSuccess := false;
  FError := '';
  FCallbackQueued := false;
  FCancelled := false;

  FUpdater := TConfigUpdater.Create(AFilePath, ARemotePath, AIntervalMinutes,
    ALastUpdated, ASingBoxCli, ALogger, AWorkDir);
  // This worker performs exactly one synchronous download. Without this the updater
  // would also run its own automatic-update loop against the same BPF file.
  FUpdater.MakeOneShotOnly;

  // Owned by TDrover, destroyed from the main thread exactly once.
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

  // Read the callback once. Cancellation sets FOnDone to nil and is only ever done
  // by the main thread, which cannot run concurrently with this code until this
  // thread has finished, so no lock is required for this snapshot.
  handler := FOnDone;
  if FCancelled or (not Assigned(handler)) then
    exit;

  // Copy everything the queued callback needs into locals so the closure never
  // captures Self; the object outlives this thread but the callback must not depend
  // on that.
  path := FFilePath;
  err := FError;
  ok := FSuccess;
  FCallbackQueued := true;

  TThread.Queue(nil,
    procedure
    begin
      handler(path, ok, err);
    end);
end;

end.
