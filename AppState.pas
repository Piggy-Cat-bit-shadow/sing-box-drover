unit AppState;

// GUI-side state that is *not* part of the sing-box config:
//   * remembered selector choices
//   * the active profile path
//   * subscription traffic metadata read from `Subscription-Userinfo`
//
// Config/profile content never lives here: BPF files own config and remote
// subscription parameters, this file owns GUI bookkeeping only.

interface

uses
  System.SysUtils, System.IOUtils, System.JSON, System.Classes,
  System.Generics.Collections, SingBoxConfig;

type
  TAppState = class
  private
    FFilePath: string;
    FSelectors: TDictionary<string, string>;
    FSubscriptions: TDictionary<string, TSubscriptionUserInfo>;
    FActiveProfilePath: string;
    FRoot: TJSONObject;

    procedure Load;
    procedure Save;
    function BuildJsonText: string;
    procedure LoadSelectors;
    procedure LoadActiveProfile;
    procedure LoadSubscriptions;
  public
    constructor Create(const filePath: string);
    destructor Destroy; override;

    function GetSelector(const AName: string; out AValue: string): boolean;
    procedure SyncSelectors(values: TDictionary<string, string>; const scope: TArray<string>);

    function GetSubscriptionInfo(const AProfilePath: string; out AInfo: TSubscriptionUserInfo): boolean;
    procedure SetSubscriptionInfo(const AProfilePath: string; const AInfo: TSubscriptionUserInfo);

    procedure Persist;

    property ActiveProfilePath: string read FActiveProfilePath write FActiveProfilePath;
  end;

implementation

uses
  System.StrUtils;

const
  KEY_SELECTORS = 'selectors';
  KEY_ACTIVE_PROFILE = 'activeProfilePath';
  KEY_SUBSCRIPTIONS = 'subscriptions';
  KEY_UPLOAD = 'upload';
  KEY_DOWNLOAD = 'download';
  KEY_TOTAL = 'total';
  KEY_EXPIRE = 'expire';

constructor TAppState.Create(const filePath: string);
begin
  FFilePath := filePath;
  FSelectors := TDictionary<string, string>.Create;
  FSubscriptions := TDictionary<string, TSubscriptionUserInfo>.Create;
  FRoot := TJSONObject.Create;
  FActiveProfilePath := '';
  Load;
end;

destructor TAppState.Destroy;
begin
  FreeAndNil(FRoot);
  FreeAndNil(FSelectors);
  FreeAndNil(FSubscriptions);
  inherited;
end;

procedure TAppState.Load;
var
  text: string;
  parsed: TJSONValue;
  newRoot: TJSONObject;
begin
  newRoot := nil;
  try
    if not TFile.Exists(FFilePath) then
      Abort;

    text := TFile.ReadAllText(FFilePath, TEncoding.UTF8);
    if text = '' then
      Abort;

    parsed := TJSONObject.ParseJSONValue(text);
    if not(parsed is TJSONObject) then
    begin
      parsed.Free;
      Abort;
    end;
    newRoot := TJSONObject(parsed);
  except
    FreeAndNil(newRoot);
  end;

  if newRoot = nil then
    newRoot := TJSONObject.Create;

  FRoot.Free;
  FRoot := newRoot;

  FSelectors.Clear;
  FSubscriptions.Clear;
  FActiveProfilePath := '';

  LoadSelectors;
  LoadActiveProfile;
  LoadSubscriptions;
end;

procedure TAppState.LoadSelectors;
var
  selObj: TJSONObject;
  pair: TJSONPair;
begin
  if not FRoot.TryGetValue<TJSONObject>(KEY_SELECTORS, selObj) then
    exit;

  for pair in selObj do
    if pair.JsonValue is TJSONString then
      FSelectors.AddOrSetValue(pair.JsonString.Value, TJSONString(pair.JsonValue).Value);
end;

procedure TAppState.LoadActiveProfile;
var
  value: string;
begin
  value := '';
  FRoot.TryGetValue(KEY_ACTIVE_PROFILE, value);
  FActiveProfilePath := trim(value);
end;

procedure TAppState.LoadSubscriptions;
var
  subsObj, infoObj: TJSONObject;
  pair: TJSONPair;
  info: TSubscriptionUserInfo;
  num: TJSONNumber;
begin
  if not FRoot.TryGetValue<TJSONObject>(KEY_SUBSCRIPTIONS, subsObj) then
    exit;

  for pair in subsObj do
  begin
    if not(pair.JsonValue is TJSONObject) then
      continue;

    infoObj := TJSONObject(pair.JsonValue);
    info := Default (TSubscriptionUserInfo);

    if infoObj.TryGetValue<TJSONNumber>(KEY_UPLOAD, num) then
      info.upload := num.AsInt64;
    if infoObj.TryGetValue<TJSONNumber>(KEY_DOWNLOAD, num) then
      info.download := num.AsInt64;
    if infoObj.TryGetValue<TJSONNumber>(KEY_TOTAL, num) then
      info.total := num.AsInt64;
    if infoObj.TryGetValue<TJSONNumber>(KEY_EXPIRE, num) then
      info.expire := num.AsInt64;

    FSubscriptions.AddOrSetValue(pair.JsonString.Value, info);
  end;
end;

function TAppState.BuildJsonText: string;
var
  removed: TJSONPair;
  selObj, subsObj, infoObj: TJSONObject;
  pair: TPair<string, string>;
  sub: TPair<string, TSubscriptionUserInfo>;
begin
  removed := FRoot.RemovePair(KEY_SELECTORS);
  if removed <> nil then
    removed.Free;

  selObj := TJSONObject.Create;
  FRoot.AddPair(KEY_SELECTORS, selObj);
  for pair in FSelectors do
    selObj.AddPair(pair.Key, pair.Value);

  removed := FRoot.RemovePair(KEY_ACTIVE_PROFILE);
  if removed <> nil then
    removed.Free;
  if FActiveProfilePath <> '' then
    FRoot.AddPair(KEY_ACTIVE_PROFILE, FActiveProfilePath);

  removed := FRoot.RemovePair(KEY_SUBSCRIPTIONS);
  if removed <> nil then
    removed.Free;

  subsObj := TJSONObject.Create;
  FRoot.AddPair(KEY_SUBSCRIPTIONS, subsObj);
  for sub in FSubscriptions do
  begin
    infoObj := TJSONObject.Create;
    infoObj.AddPair(KEY_UPLOAD, TJSONNumber.Create(sub.Value.upload));
    infoObj.AddPair(KEY_DOWNLOAD, TJSONNumber.Create(sub.Value.download));
    infoObj.AddPair(KEY_TOTAL, TJSONNumber.Create(sub.Value.total));
    infoObj.AddPair(KEY_EXPIRE, TJSONNumber.Create(sub.Value.expire));
    subsObj.AddPair(sub.Key, infoObj);
  end;

  result := FRoot.Format(2);
end;

procedure TAppState.Save;
begin
  TFile.WriteAllBytes(FFilePath, TEncoding.UTF8.GetBytes(BuildJsonText));
end;

procedure TAppState.Persist;
begin
  Save;
end;

function TAppState.GetSelector(const AName: string; out AValue: string): boolean;
begin
  result := FSelectors.TryGetValue(AName, AValue);
end;

procedure TAppState.SyncSelectors(values: TDictionary<string, string>; const scope: TArray<string>);
var
  pair: TPair<string, string>;
  name: string;
begin
  if (values.Count = 0) and (length(scope) = 0) then
    exit;

  for name in scope do
    if not values.ContainsKey(name) then
      FSelectors.Remove(name);

  for pair in values do
    FSelectors.AddOrSetValue(pair.Key, pair.Value);

  Save;
end;

function TAppState.GetSubscriptionInfo(const AProfilePath: string; out AInfo: TSubscriptionUserInfo): boolean;
begin
  AInfo := Default (TSubscriptionUserInfo);
  if AProfilePath = '' then
    exit(false);

  result := FSubscriptions.TryGetValue(AProfilePath, AInfo);
end;

procedure TAppState.SetSubscriptionInfo(const AProfilePath: string; const AInfo: TSubscriptionUserInfo);
begin
  if AProfilePath = '' then
    exit;

  FSubscriptions.AddOrSetValue(AProfilePath, AInfo);
  try
    Save;
  except
    // A read-only install directory must not break the running app.
  end;
end;

end.
