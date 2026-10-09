unit Main;

// Tray shell UI.
//
// The menu is rebuilt from scratch every time it is shown, so it can never go
// stale after a profile switch, a core restart or a subscription update.
//
// There is deliberately no TUN switch and no system proxy switch: the config
// decides both, and the app asks for elevation / sets the Windows proxy on its
// own. Left click on the tray icon simply brings up the same menu - no hidden
// shortcuts that silently change the network mode.

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.Menus,
  System.Net.HttpClient, System.Net.URLClient, System.JSON, System.IOUtils,
  System.Generics.Collections, System.DateUtils, Options, Drover, AppElevation,
  AppArgs, SingBoxConfig, ElevatedTrayIcon, Autostart, Winapi.ShellAPI,
  CoreSupervisor, AppStrings, SubscriptionManager, ConfigReader, SingBoxBpf;

type
  TPendingSelectorRequests = TDictionary<NativeInt, TMenuItem>;

  TUpdateDisplayState = (udsIdle, udsUpdating, udsSuccess, udsFailed);

  TfrmMain = class(TForm)
    PopupMenu: TPopupMenu;
    miStatus: TMenuItem;
    miSubscriptions: TMenuItem;
    miSubProfilesEnd: TMenuItem;
    miUpdateNow: TMenuItem;
    miAutoUpdate: TMenuItem;
    miLastUpdated: TMenuItem;
    miTraffic: TMenuItem;
    miExpire: TMenuItem;
    miSubSeparator: TMenuItem;
    miAddSubscription: TMenuItem;
    miOpenProfilesDir: TMenuItem;
    miSelectors: TMenuItem;
    miBeforeMore: TMenuItem;
    miMore: TMenuItem;
    miCoreVersion: TMenuItem;
    miRestartCore: TMenuItem;
    miAutostart: TMenuItem;
    miHomepage: TMenuItem;
    miQuit: TMenuItem;
    Timer: TTimer;
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure FormCreate(Sender: TObject);
    procedure miQuitClick(Sender: TObject);
    procedure miSelectorClick(Sender: TObject);
    procedure miAutostartClick(Sender: TObject);
    procedure miRestartCoreClick(Sender: TObject);
    procedure miHomepageClick(Sender: TObject);
    procedure miUpdateNowClick(Sender: TObject);
    procedure miAutoUpdateClick(Sender: TObject);
    procedure miAddSubscriptionClick(Sender: TObject);
    procedure miOpenProfilesDirClick(Sender: TObject);
    procedure miProfileClick(Sender: TObject);
    procedure miDeleteProfileClick(Sender: TObject);
    procedure PopupMenuPopup(Sender: TObject);
    procedure TimerTimer(Sender: TObject);
    // Bounded fallback for the close path; see SHUTDOWN_POLL_INTERVAL_MS.
    procedure PollShutdownProgress;
    procedure TrayIconMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer);
  private
    TrayIcon: TElevatedTrayIcon;
    FDrover: TDrover;
    FSystemProxySetByUs: boolean;
    FClosePending: boolean;
    FLastRequestId: NativeInt;
    FPendingSelectorRequests: TPendingSelectorRequests;
    FUpdateState: TUpdateDisplayState;
    FUpdateError: string;
    FLastPopupTick: UInt64;
    FScheduledUpdateTick: UInt64;
    FEventPending: boolean;
    FProfilePaths: TArray<string>;

    function NewRequestId: NativeInt;
    procedure UpdateTrayIcon;
    procedure SetCoreStatus(state: TCoreState);
    procedure HandleDroverEvent(event: TDroverEvent);
    procedure WMDroverCanClose(var msg: TMessage); message WM_DROVER_CAN_CLOSE;
    procedure WMDroverUpdaterEvent(var msg: TMessage); message WM_DROVER_UPDATER_EVENT;
    procedure WMAutostartResult(var msg: TMessage); message WM_AUTOSTART_RESULT;
    procedure ShowBalloon(AText, ATitle: string; AFlags: TBalloonFlags = bfInfo; ATimeout: integer = 10000);
    procedure ShowOnlyExitInTray;
    procedure InitAutostart;
    procedure StartAutostartThread(AAction: TAutostartAction);
    procedure HandleAutostartResult(const r: TAutostartResult);

    procedure RebuildMenu;
    procedure RebuildSelectorMenu;
    procedure RebuildSubscriptionsMenu;
    procedure ApplyDrainUpdateResults;
    procedure ScheduleNextUpdateCheck;
    procedure MarkUpdateState(AState: TUpdateDisplayState; const AError: string = '');
    function FormatBytes(AValue: int64): string;
    function FormatExpire(AUnix: int64): string;
    function FormatLastUpdated(AMs: int64): string;
  public
    destructor Destroy; override;
    procedure InitDrover(ADrover: TDrover);
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.dfm}

const
  // AutoUpdate defaults to enabled when a profile was created without the flag.
  MENU_IDX_NONE = -1;
  // Guard against the popup being shown twice for one click (once by VCL, once
  // by our own OnMouseUp handler).
  POPUP_DEBOUNCE_MS = 400;
  // A timer tick used to drive both the update and the scheduled refresh check.
  TIMER_ID = 1;
  // Bounded fallback while closing: how often the GUI re-checks whether every
  // background worker has stopped. TThread.OnTerminate is delivered by queueing a
  // method call, so it is not a guaranteed signal and must not be the only route
  // to a completed close.
  SHUTDOWN_POLL_INTERVAL_MS = 100;

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  FSystemProxySetByUs := false;
  FClosePending := false;
  FLastRequestId := 0;
  FUpdateState := udsIdle;
  FUpdateError := '';
  FLastPopupTick := 0;
  FScheduledUpdateTick := 0;
  FEventPending := false;
  FPendingSelectorRequests := TPendingSelectorRequests.Create;

  Caption := APP_NAME_WINDOWS;

  TrayIcon := TElevatedTrayIcon.Create(self);
  TrayIcon.PopupMenu := PopupMenu;
  TrayIcon.Hint := APP_NAME;
  TrayIcon.OnMouseUp := TrayIconMouseUp;

  PopupMenu.OnPopup := PopupMenuPopup;
  Timer.Interval := 30000;
  Timer.Enabled := false;

  InitAutostart;
end;

destructor TfrmMain.Destroy;
begin
  FreeAndNil(FPendingSelectorRequests);
  inherited;
end;

function TfrmMain.NewRequestId: NativeInt;
begin
  inc(FLastRequestId);
  result := FLastRequestId;
end;

procedure TfrmMain.InitDrover(ADrover: TDrover);
begin
  FDrover := ADrover;
  FDrover.NotifyHandle := Handle;

  // Automatic Windows integration, driven purely by the config:
  //   * a mixed/http inbound  -> point the system proxy at it
  //   * no mixed inbound      -> do nothing, do not complain
  if Assigned(FDrover) and (FDrover.sbConfig.proxyPort > 0) then
  begin
    FSystemProxySetByUs := FDrover.EnableSystemProxy;
    if not FSystemProxySetByUs then
      ShowBalloon(DIALOG_PROXY_FAILED, DIALOG_TITLE_ERROR, bfError);
  end;

  FDrover.OnEvent := HandleDroverEvent;

  UpdateTrayIcon;
  SetCoreStatus(TCoreState.csStarting);
  RebuildMenu;

  TrayIcon.Visible := true;
  ScheduleNextUpdateCheck;
end;

procedure TfrmMain.UpdateTrayIcon;
var
  resourceName: string;
begin
  // The icon reflects the core lifecycle only: there is no user-facing mode
  // switch left to mirror.
  case FDrover.CoreState of
    csRunning:
      begin
        if FDrover.sbConfig.hasTunInbound then
          resourceName := 'TRAY_ICON_TUN'
        else
          resourceName := 'TRAY_ICON';
      end;
    csStarting, csStopping:
      resourceName := 'TRAY_ICON_DISABLED';
    csFailed:
      resourceName := 'TRAY_ICON_DISABLED';
  else
    resourceName := 'TRAY_ICON_DISABLED';
  end;

  try
    TrayIcon.Icon.LoadFromResourceName(HInstance, resourceName);
  except
    // A missing resource must not take the tray down.
  end;
end;

procedure TfrmMain.SetCoreStatus(state: TCoreState);
var
  caption: string;
begin
  case state of
    csRunning:
      caption := STATUS_RUNNING;
    csStarting:
      caption := STATUS_STARTING;
    csStopping:
      caption := STATUS_STOPPING;
    csFailed:
      caption := STATUS_FAILED;
  else
    caption := STATUS_STOPPED;
  end;

  miStatus.Caption := caption;
  UpdateTrayIcon;
end;

procedure TfrmMain.HandleDroverEvent(event: TDroverEvent);
var
  pendingItem: TMenuItem;
  coreEvent: TCoreEvent;
begin
  case event.kind of
    dekError:
      ShowBalloon(event.msg, DIALOG_CORE_START_FAILED, bfError);

    dekRunning:
      begin
        SetCoreStatus(TCoreState.csRunning);
        RebuildMenu;
      end;

    dekSubscriptionUpdated:
      MarkUpdateState(udsIdle);

    dekCoreEvent:
      begin
        coreEvent := event.coreEvent;
        case coreEvent.kind of
          cekSelectorDone:
            if FPendingSelectorRequests.TryGetValue(coreEvent.requestId, pendingItem) then
            begin
              FPendingSelectorRequests.Remove(coreEvent.requestId);
              pendingItem.Enabled := true;
            end;
        end;
      end;
  end;
end;

procedure TfrmMain.WMDroverUpdaterEvent(var msg: TMessage);
begin
  // The message only carries the notification; the actual results are pulled
  // from the drover's queue so nothing can be delivered twice.
  if msg.LParam <> 0 then
    Dispose(PUpdaterEvent(msg.LParam));

  ApplyDrainUpdateResults;
end;

procedure TfrmMain.ApplyDrainUpdateResults;
var
  filePath: string;
  attempt: TUpdateAttemptResult;
begin
  while FDrover.TryApplyUpdate(filePath, attempt) do
  begin
    if attempt.success then
    begin
      // filePath is the profile the updater finished; only the active one is
      // allowed to have restarted the core.
      MarkUpdateState(udsSuccess);
      SetCoreStatus(FDrover.CoreState);
    end
    else
    begin
      MarkUpdateState(udsFailed, attempt.error);
      ShowBalloon(DIALOG_SUBSCRIBE_FAILED + ': ' + attempt.error, DIALOG_TITLE_ERROR, bfError);
    end;
  end;

  RebuildMenu;
  ScheduleNextUpdateCheck;
end;

procedure TfrmMain.MarkUpdateState(AState: TUpdateDisplayState; const AError: string);
begin
  FUpdateState := AState;
  FUpdateError := AError;
  RebuildSubscriptionsMenu;
end;

procedure TfrmMain.PopupMenuPopup(Sender: TObject);
begin
  FLastPopupTick := GetTickCount64;
  RebuildMenu;
end;

procedure TfrmMain.TrayIconMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  // Left click must not change the network mode. Depending on the VCL version
  // TTrayIcon may or may not bring up PopupMenu itself, so show it here as well
  // and rely on the debounce to avoid a double popup.
  if Button <> TMouseButton.mbLeft then
    exit;

  if GetTickCount64 - FLastPopupTick < POPUP_DEBOUNCE_MS then
    exit;

  FLastPopupTick := GetTickCount64;
  PopupMenu.Popup(Mouse.CursorPos.X, Mouse.CursorPos.Y);
end;

procedure TfrmMain.RebuildMenu;
begin
  SetCoreStatus(FDrover.CoreState);
  RebuildSelectorMenu;
  RebuildSubscriptionsMenu;

  miMore.Caption := MENU_MORE;
  miRestartCore.Caption := MENU_RESTART_CORE;
  miAutostart.Caption := MENU_AUTOSTART;
  miHomepage.Caption := MENU_GITHUB;
  miQuit.Caption := MENU_QUIT;

  // The version string comes from `sing-box.exe version` itself; the GUI keeps
  // no second copy of it.
  if FDrover.CoreVersion = '' then
    miCoreVersion.Caption := MENU_CORE_VERSION + ': ' + MENU_CORE_VERSION_UNKNOWN
  else
    miCoreVersion.Caption := MENU_CORE_VERSION + ': ' + FDrover.CoreVersion;
end;

procedure TfrmMain.RebuildSelectorMenu;
var
  selectors: TConfigSelectors;
  selector: TConfigSelector;
  selectorItem, outboundItem: TMenuItem;
  selectorI, outboundI: integer;
begin
  miSelectors.Clear;

  selectors := FDrover.Selectors;

  // No clash_api in the config -> no selector UI. Nothing is ever injected to
  // make this menu appear.
  if not FDrover.sbConfig.clashApi.IsConfigured then
  begin
    miSelectors.Visible := false;
    exit;
  end;

  if (Length(selectors) < 1) or (Length(selectors) > 50) then
  begin
    miSelectors.Visible := false;
    exit;
  end;

  miSelectors.Visible := true;
  miSelectors.Caption := '[ ' + IntToStr(Length(selectors)) + ' ]';

  for selectorI := Low(selectors) to High(selectors) do
  begin
    selector := selectors[selectorI];

    selectorItem := TMenuItem.Create(miSelectors);
    selectorItem.Caption := selector.name;

    for outboundI := Low(selector.outbounds) to High(selector.outbounds) do
    begin
      outboundItem := TMenuItem.Create(selectorItem);
      outboundItem.Caption := selector.outbounds[outboundI];
      outboundItem.AutoCheck := true;
      outboundItem.RadioItem := true;
      outboundItem.OnClick := miSelectorClick;
      outboundItem.Tag := selectorI * 1000 + outboundI;
      outboundItem.Checked := (outboundI = selector.defaultIndex);
      outboundItem.GroupIndex := selectorI + 10;
      selectorItem.Add(outboundItem);
    end;

    miSelectors.Add(selectorItem);
  end;
end;

procedure TfrmMain.RebuildSubscriptionsMenu;
var
  profiles: TProfileList;
  profile: TSubscriptionProfile;
  item, deleteItem, updateItem: TMenuItem;
  i, activeIndex: integer;
  activePath, updateCaption: string;
  info: TSubscriptionUserInfo;
  used: int64;
begin
  miSubscriptions.Caption := MENU_SUBSCRIPTIONS;

  profiles := FDrover.ListProfiles;
  activePath := FDrover.ActiveProfilePath;

  // --- profile list, inserted just before the tail separator ---------------
  while miSubscriptions.Count > 0 do
  begin
    item := miSubscriptions.Items[0];
    if item = miSubProfilesEnd then
      break;
    miSubscriptions.Remove(item);
    item.Free;
  end;

  SetLength(FProfilePaths, Length(profiles));
  for i := 0 to High(profiles) do
    FProfilePaths[i] := profiles[i].filePath;


  for i := 0 to High(profiles) do
  begin
    profile := profiles[i];

    item := TMenuItem.Create(miSubscriptions);
    item.Caption := profile.name;
    item.AutoCheck := true;
    item.RadioItem := true;
    item.Checked := TSubscriptionManager.SamePath(profile.filePath, activePath);
    item.GroupIndex := 1;
    item.Tag := i;
    item.OnClick := miProfileClick;

    // Tag stays -1 so the update entry can carry the profile index.
    updateItem := TMenuItem.Create(item);
    updateItem.Caption := MENU_UPDATE_NOW;
    updateItem.Tag := i;
    updateItem.OnClick := miUpdateNowClick;
    item.Add(updateItem);

    deleteItem := TMenuItem.Create(item);
    deleteItem.Caption := MENU_DELETE_SUBSCRIPTION;
    deleteItem.Tag := i;
    deleteItem.OnClick := miDeleteProfileClick;
    item.Add(deleteItem);

    miSubscriptions.Insert(i, item);
  end;

  if Length(profiles) = 0 then
  begin
    item := TMenuItem.Create(miSubscriptions);
    item.Caption := MENU_NO_SUBSCRIPTION;
    item.Enabled := false;
    miSubscriptions.Insert(0, item);
  end;

  // --- update row ---------------------------------------------------------
  case FUpdateState of
    udsUpdating:
      updateCaption := MENU_UPDATING;
    udsSuccess:
      updateCaption := MENU_UPDATED_JUST_NOW;
    udsFailed:
      updateCaption := MENU_UPDATE_FAILED;
  else
    updateCaption := MENU_UPDATE_NOW;
  end;

  // Tag names the profile the button applies to: the active one, or -1 when
  // there is nothing to update.
  activeIndex := MENU_IDX_NONE;
  for i := 0 to High(profiles) do
    if TSubscriptionManager.SamePath(profiles[i].filePath, activePath) then
    begin
      activeIndex := i;
      break;
    end;

  miUpdateNow.Caption := updateCaption;
  miUpdateNow.Tag := activeIndex;
  miUpdateNow.Enabled := (FUpdateState <> udsUpdating) and (activeIndex >= 0) and
    FDrover.HasActiveRemoteProfile;

  miAutoUpdate.Caption := MENU_AUTO_UPDATE;
  miAutoUpdate.Checked := FDrover.HasActiveRemoteProfile;
  miAutoUpdate.Enabled := FDrover.HasActiveRemoteProfile;

  if FDrover.ActiveProfileLastUpdated <= 0 then
    miLastUpdated.Caption := MENU_LAST_UPDATED + ': ' + MENU_NEVER
  else
    miLastUpdated.Caption := MENU_LAST_UPDATED + ': ' + FormatLastUpdated(FDrover.ActiveProfileLastUpdated);

  // --- traffic / expiry ---------------------------------------------------
  miTraffic.Visible := false;
  miExpire.Visible := false;

  if (activePath <> '') and FDrover.GetSubscriptionInfo(activePath, info) then
  begin
    if info.HasTraffic then
    begin
      used := info.upload + info.download;
      miTraffic.Caption := MENU_TRAFFIC_USED + ': ' + FormatBytes(used) + ' / ' + FormatBytes(info.total);
      miTraffic.Visible := true;
    end;

    if info.HasExpire then
    begin
      miExpire.Caption := MENU_TRAFFIC_EXPIRES + ': ' + FormatExpire(info.expire);
      miExpire.Visible := true;
    end;
  end;

  miAddSubscription.Caption := MENU_ADD_SUBSCRIPTION;
  miAddSubscription.Enabled := true;
  miOpenProfilesDir.Caption := MENU_OPEN_PROFILES_DIR;
  miOpenProfilesDir.Enabled := true;
end;

function TfrmMain.FormatBytes(AValue: int64): string;
const
  KB = 1024;
  MB = 1024 * 1024;
  GB = int64(1024) * 1024 * 1024;
begin
  if AValue >= GB then
    result := FormatFloat('0.##', AValue / GB) + ' GB'
  else if AValue >= MB then
    result := FormatFloat('0.#', AValue / MB) + ' MB'
  else
    result := FormatFloat('0.#', AValue / KB) + ' KB';
end;

function TfrmMain.FormatExpire(AUnix: int64): string;
var
  localTime: TDateTime;
begin
  result := MENU_CORE_VERSION_UNKNOWN;
  if AUnix <= 0 then
    exit;

  try
    localTime := UnixToDateTime(AUnix, false);
    result := FormatDateTime('yyyy-mm-dd', localTime);
  except
    result := MENU_CORE_VERSION_UNKNOWN;
  end;
end;

function TfrmMain.FormatLastUpdated(AMs: int64): string;
var
  localTime: TDateTime;
  today: TDateTime;
begin
  result := MENU_NEVER;
  if AMs <= 0 then
    exit;

  try
    localTime := UnixToDateTime(AMs div 1000, false);
    today := Date;
    if Trunc(localTime) = Trunc(today) then
      result := FormatDateTime('hh:nn', localTime)
    else
      result := FormatDateTime('mm-dd hh:nn', localTime);
  except
    result := MENU_NEVER;
  end;
end;

procedure TfrmMain.ScheduleNextUpdateCheck;
begin
  // Lightweight: a single timer tick re-evaluates "is a scheduled update due".
  // The actual HTTP work always happens inside the one ConfigUpdater worker.
  FScheduledUpdateTick := GetTickCount64 + FDrover.NextIntervalMs;

  if not Timer.Enabled then
  begin
    Timer.Interval := 30000;
    Timer.Enabled := true;
  end;
end;

procedure TfrmMain.TimerTimer(Sender: TObject);
begin
  if FClosePending then
  begin
    // The same timer is reused for the bounded shutdown fallback; the scheduled
    // update check must not run while the GUI is closing.
    PollShutdownProgress;
    exit;
  end;

  if not Assigned(FDrover) then
    exit;

  if int64(GetTickCount64 - FScheduledUpdateTick) < 0 then
    exit;

  if not FDrover.HasActiveRemoteProfile then
  begin
    ScheduleNextUpdateCheck;
    exit;
  end;

  if FUpdateState = udsUpdating then
  begin
    ScheduleNextUpdateCheck;
    exit;
  end;

  MarkUpdateState(udsUpdating);
  FDrover.UpdateProfileNow(FDrover.ActiveProfilePath);
  ScheduleNextUpdateCheck;
end;

procedure TfrmMain.miSelectorClick(Sender: TObject);
var
  item: TMenuItem;
  i: integer;
  selectorI, outboundI: integer;
  requestId: NativeInt;
begin
  if not(Sender is TMenuItem) then
    exit;

  item := TMenuItem(Sender);
  i := item.Tag;

  selectorI := i div 1000;
  outboundI := i mod 1000;

  item.Checked := true;

  requestId := NewRequestId;

  if not FDrover.EditSelector(selectorI, outboundI, requestId) then
    exit;

  FPendingSelectorRequests.Add(requestId, item);
  item.Enabled := false;
end;

procedure TfrmMain.miProfileClick(Sender: TObject);
var
  item: TMenuItem;
  filePath, err: string;
begin
  if not(Sender is TMenuItem) then
    exit;

  item := TMenuItem(Sender);
  if (item.Tag < 0) or (item.Tag > High(FProfilePaths)) then
    exit;

  filePath := FProfilePaths[item.Tag];
  if FDrover.IsActiveProfile(filePath) then
    exit;

  if not FDrover.SwitchProfile(filePath, err) then
  begin
    ShowBalloon(err, DIALOG_TITLE_ERROR, bfError);
    exit;
  end;

  // Switching profiles re-parses the config, so the Windows proxy and the
  // selector/clash API metadata may all have changed.
  //
  // Only the value this application actually installed is ever rolled back:
  // AppliedSystemProxyServer is '' once another tool owns the setting, and in that
  // case the new owner's configuration is left untouched.
  if FDrover.sbConfig.proxyPort > 0 then
    FSystemProxySetByUs := FDrover.EnableSystemProxy or FSystemProxySetByUs
  else if (FDrover.AppliedSystemProxyServer <> '') then
  begin
    FDrover.DisableSystemProxy;
    FSystemProxySetByUs := false;
  end;

  MarkUpdateState(udsIdle);
  SetCoreStatus(FDrover.CoreState);
  RebuildMenu;
  ScheduleNextUpdateCheck;
end;

procedure TfrmMain.miDeleteProfileClick(Sender: TObject);
var
  item: TMenuItem;
  filePath: string;
begin
  if not(Sender is TMenuItem) then
    exit;

  item := TMenuItem(Sender);
  if (item.Tag < 0) or (item.Tag > High(FProfilePaths)) then
    exit;

  filePath := FProfilePaths[item.Tag];

  if FDrover.IsActiveProfile(filePath) then
  begin
    ShowBalloon(DIALOG_ACTIVE_CANNOT_DELETE, DIALOG_TITLE_INFO, bfInfo);
    exit;
  end;

  if MessageDlg(DIALOG_DELETE_CONFIRM, mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    exit;

  if not FDrover.DeleteSubscription(filePath) then
    ShowBalloon(DIALOG_DELETE_FAILED, DIALOG_TITLE_ERROR, bfError);

  RebuildMenu;
end;

// The update entry always targets one explicit profile, and the menu item carries it in
// Tag (-1 = the active profile).
procedure TfrmMain.miUpdateNowClick(Sender: TObject);
var
  target, activePath, err: string;
begin
  if not(Sender is TMenuItem) then
    exit;

  activePath := FDrover.ActiveProfilePath;

  if TMenuItem(Sender).Tag >= 0 then
  begin
    if (TMenuItem(Sender).Tag > High(FProfilePaths)) then
      exit;
    target := FProfilePaths[TMenuItem(Sender).Tag];
  end
  else
    target := activePath;

  if target = '' then
  begin
    ShowBalloon(MENU_NO_SUBSCRIPTION, DIALOG_TITLE_INFO, bfInfo);
    exit;
  end;

  MarkUpdateState(udsUpdating);

  if FDrover.IsActiveProfile(target) then
  begin
    // The long-lived updater handles it; it is already serialized with the
    // automatic interval.
    FDrover.UpdateProfileNow(target);
    exit;
  end;

  // An inactive profile gets a one-shot worker that only writes the BPF file.
  // Updating a profile the user did not ask to switch to must never change the
  // active profile or disturb the running core - switching is a separate, explicit
  // action ("switch to this subscription").
  //
  // The completion callback is an anonymous method, so it captures Target and the
  // local error string by value. It must not need the worker instance, which is
  // freed by the thread itself as soon as it terminates. The worker is still owned
  // by the drover for join purposes, so it cannot outlive the form.
  if not FDrover.StartProfileUpdate(target,
    procedure(const AFilePath: string; ASuccess: boolean; const AError: string)
    begin
      // ForceQueue, not Queue: this runs on the main thread already, and the worker
      // is freed on its own termination, so the cleanup must be deferred rather
      // than run while the worker's queued callback is still on the stack.
      TThread.ForceQueue(nil,
        procedure
        begin
          if Assigned(FDrover) then
            FDrover.CleanupFinishedUpdateWorkers;
        end);

      if FClosePending or (not Assigned(FDrover)) then
        exit;

      if not ASuccess then
      begin
        MarkUpdateState(udsFailed, AError);
        ShowBalloon(DIALOG_SUBSCRIBE_FAILED + ': ' + AError, DIALOG_TITLE_ERROR, bfError);
        exit;
      end;

      MarkUpdateState(udsSuccess);
      RebuildMenu;
      ScheduleNextUpdateCheck;

      // Always confirm what happened: without this, a successful update of a
      // profile that was deliberately not switched to would look like a no-op.
      ShowBalloon(DIALOG_SUBSCRIBE_UPDATED_KEPT, DIALOG_TITLE_INFO, bfInfo);
    end, err) then
  begin
    MarkUpdateState(udsFailed, err);
    ShowBalloon(DIALOG_SUBSCRIBE_FAILED + ': ' + err, DIALOG_TITLE_ERROR, bfError);
  end;
end;

procedure TfrmMain.miAutoUpdateClick(Sender: TObject);
var
  filePath: string;
  profile: TBpfProfile;
  loaded: TSubscriptionProfile;
begin
  filePath := FDrover.ActiveProfilePath;
  if filePath = '' then
    exit;

  try
    loaded := TSubscriptionManager.Load(filePath);
  except
    on E: Exception do
    begin
      ShowBalloon(E.Message, DIALOG_TITLE_ERROR, bfError);
      exit;
    end;
  end;

  profile := ReadBpfProfileFromFile(filePath);
  profile.autoUpdate := not loaded.autoUpdate;

  if profile.autoUpdate and (profile.autoUpdateInterval <= 0) then
    profile.autoUpdateInterval := DEFAULT_UPDATE_INTERVAL_MINUTES;

  if not TSubscriptionManager.Write(filePath, profile) then
  begin
    ShowBalloon(DIALOG_TITLE_ERROR, DIALOG_TITLE_ERROR, bfError);
    exit;
  end;

  // Rebuild the worker so the new auto-update flag takes effect immediately.
  // The running core is not touched: only the download schedule changed.
  FDrover.RefreshUpdater;
  RebuildMenu;
  ScheduleNextUpdateCheck;
end;

procedure TfrmMain.miAddSubscriptionClick(Sender: TObject);
var
  name, url, filePath: string;
  prompts: array [0 .. 1] of string;
  values: array [0 .. 1] of string;
begin
  name := '';
  url := 'https://';

  // InputQuery's prompts/values parameters are var-parameters (array of string),
  // so real arrays are required; an inline literal cannot be passed to them.
  prompts[0] := DIALOG_ADD_NAME_PROMPT;
  prompts[1] := DIALOG_ADD_URL_PROMPT;
  values[0] := name;
  values[1] := url;

  if not InputQuery(DIALOG_ADD_TITLE, prompts, values) then
    exit;

  name := values[0];
  url := values[1];

  name := trim(name);
  url := trim(url);

  if (not SameText(Copy(url, 1, 7), 'http://')) and (not SameText(Copy(url, 1, 8), 'https://')) then
  begin
    ShowBalloon(DIALOG_BAD_URL, DIALOG_TITLE_ERROR, bfError);
    exit;
  end;

  if name = '' then
    name := url;

  if not FDrover.AddSubscription(name, url, filePath) then
  begin
    ShowBalloon(DIALOG_ADD_FAILED, DIALOG_TITLE_ERROR, bfError);
    exit;
  end;

  RebuildMenu;

  // The placeholder profile is filled in by the same single updater worker;
  // when it succeeds it becomes the active profile (see ApplyPendingReload).
  MarkUpdateState(udsUpdating);
  FDrover.UpdateProfileNow(filePath);
end;

procedure TfrmMain.miOpenProfilesDirClick(Sender: TObject);
begin
  if not FDrover.OpenProfilesDir then
    ShowBalloon(DIALOG_OPEN_DIR_FAILED, DIALOG_TITLE_ERROR, bfError);
end;

procedure TfrmMain.miRestartCoreClick(Sender: TObject);
begin
  if FClosePending then
    exit;

  // Restarts the core only. DoStart stops the old process first, so this is a
  // single supervisor command - the GUI itself is never restarted.
  FDrover.PersistRuntimeState;
  FDrover.RestartCore;
  SetCoreStatus(TCoreState.csStarting);
end;

procedure TfrmMain.miHomepageClick(Sender: TObject);
begin
  ShellExecute(0, 'open', PChar(APP_HOMEPAGE), nil, nil, SW_SHOWNORMAL);
end;

procedure TfrmMain.miQuitClick(Sender: TObject);
begin
  Close;
end;

procedure TfrmMain.miAutostartClick(Sender: TObject);
var
  flag: TAppFlag;
  action: TAutostartAction;
begin
  if FClosePending then
    exit;

  if miAutostart.Checked then
  begin
    flag := afAutostartDisable;
    action := aaDisable;
  end
  else
  begin
    flag := afAutostartEnable;
    action := aaEnable;
  end;

  if not IsProcessElevated then
  begin
    FDrover.PersistRuntimeState;
    if LaunchSelf(FlagsToCmdLine([flag, afRestart]), Handle) then
      Close;
    exit;
  end;

  StartAutostartThread(action);
end;

procedure TfrmMain.InitAutostart;
var
  flags: TAppFlags;
  initialAction: TAutostartAction;
begin
  miAutostart.Enabled := false;
  miAutostart.Checked := false;

  flags := GetAppFlags;
  if afAutostartEnable in flags then
    initialAction := aaEnable
  else if afAutostartDisable in flags then
    initialAction := aaDisable
  else
    initialAction := aaCheck;

  StartAutostartThread(initialAction);
end;

procedure TfrmMain.StartAutostartThread(AAction: TAutostartAction);
begin
  miAutostart.Enabled := false;
  TAutostartThread.Create(AAction, Handle);
end;

procedure TfrmMain.WMAutostartResult(var msg: TMessage);
var
  p: PAutostartResult;
begin
  p := PAutostartResult(msg.LParam);
  if p = nil then
    exit;
  try
    HandleAutostartResult(p^);
  finally
    Dispose(p);
  end;
end;

procedure TfrmMain.HandleAutostartResult(const r: TAutostartResult);
begin
  miAutostart.Enabled := r.state <> asUnknown;
  miAutostart.Checked := r.state = asEnabled;

  if (not r.success) and (r.action <> aaCheck) then
    ShowBalloon(r.errorMsg, DIALOG_TITLE_ERROR, bfError);
end;

procedure TfrmMain.ShowBalloon(AText, ATitle: string; AFlags: TBalloonFlags = bfInfo; ATimeout: integer = 10000);
begin
  if (AFlags = bfError) and (ATitle = '') then
    ATitle := DIALOG_TITLE_ERROR;

  TrayIcon.BalloonHint := AText;
  TrayIcon.BalloonTitle := ATitle;
  TrayIcon.BalloonFlags := AFlags;
  TrayIcon.BalloonTimeout := ATimeout;
  TrayIcon.ShowBalloonHint;
end;

procedure TfrmMain.FormCloseQuery(Sender: TObject; var CanClose: boolean);
begin
  if not Assigned(FDrover) then
  begin
    CanClose := true;
    exit;
  end;

  FClosePending := true;
  PopupMenu.OnPopup := nil;

  if (FDrover.AppliedSystemProxyServer <> '') then
  begin
    // Restores the proxy value captured before we changed it. If another tool has
    // taken the setting over meanwhile, SystemProxy declines to touch it.
    FDrover.DisableSystemProxy;
    FSystemProxySetByUs := false;
  end;

  ShowOnlyExitInTray;

  // The drover needs a moment to stop the core, so the first call normally returns
  // False. Close is then completed by WM_DROVER_CAN_CLOSE, with the timer below as
  // an independent fallback: TThread.OnTerminate is delivered by queueing a method
  // call, so relying on it alone once left the process resident forever.
  if FDrover.Shutdown then
  begin
    CanClose := true;
    exit;
  end;

  Timer.Interval := SHUTDOWN_POLL_INTERVAL_MS;
  Timer.Enabled := true;
  CanClose := false;
end;

procedure TfrmMain.WMDroverCanClose(var msg: TMessage);
begin
  if not FClosePending then
    exit;

  EndMenu;
  PostMessage(Handle, WM_CLOSE, 0, 0);
end;

// Bounded fallback for the close path. If WM_DROVER_CAN_CLOSE is ever lost, this
// still finishes the shutdown instead of leaving a headless process behind.
procedure TfrmMain.PollShutdownProgress;
begin
  if (not FClosePending) or (not Assigned(FDrover)) then
    exit;

  if FDrover.PollShutdown then
    PostMessage(Handle, WM_DROVER_CAN_CLOSE, 0, 0);
end;

procedure TfrmMain.ShowOnlyExitInTray;
var
  item: TMenuItem;
begin
  for item in PopupMenu.Items do
    item.Visible := (item = miQuit);
end;

end.
