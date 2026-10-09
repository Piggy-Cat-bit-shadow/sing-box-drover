unit ConfigReader;

// Reads the config source and parses GUI-side metadata out of it.
//
// Contract (see project spec section 4/5/6):
//   * The original config text (`TConfigSource.jsonText`) is what gets handed to
//     the core. It is never rewritten, trimmed or re-serialized.
//   * `ReadSingBoxConfig` parses a throw-away copy purely to collect metadata.
//   * No unit here removes TUN inbounds or injects `experimental.clash_api`.

interface

uses
  System.SysUtils, System.JSON, System.IOUtils, System.Generics.Collections,
  JsonUtils, SingBoxConfig, SingBoxBpf;

function ReadConfigSource(configPath: string): TConfigSource;
function ReadSingBoxConfig(const jsonText: string): TSingBoxConfig;

// True when a usable mixed/http inbound was found, i.e. the Windows system
// proxy can be pointed at this config. A TUN-only config returns False and is
// still a perfectly valid config.
function HasUsableProxyInbound(const cfg: TSingBoxConfig): boolean;

implementation

function ReadConfigSource(configPath: string): TConfigSource;
var
  configBytes: TBytes;

  function Utf8TextFromBytes(const data: TBytes): string;
  var
    offset: integer;
  begin
    offset := 0;
    if (Length(data) >= 3) and (data[0] = $EF) and (data[1] = $BB) and (data[2] = $BF) then
      offset := 3;

    result := TEncoding.UTF8.GetString(data, offset, Length(data) - offset);
  end;

begin
  result := Default (TConfigSource);
  result.filePath := configPath;

  if not TFile.Exists(configPath) then
    raise Exception.Create('Configuration file not found: ' + configPath);

  try
    configBytes := TFile.ReadAllBytes(configPath);
  except
    raise Exception.Create('Failed to read configuration file.');
  end;

  if LooksLikeBpfProfileData(configBytes) then
  begin
    result.format := csfBpf;
    result.bpfProfile := DecodeBpfProfile(configBytes);
    result.jsonText := result.bpfProfile.configJson;
  end
  else
  begin
    result.format := csfJson;
    result.jsonText := Utf8TextFromBytes(configBytes);
  end;
end;

function ReadSingBoxConfig(const jsonText: string): TSingBoxConfig;
var
  normalizedJson: string;
  rootValue: TJSONValue;
  rootObj: TJSONObject;
  outboundName: string;
  itemsArr: TJSONArray;
  outboundI: integer;
  itemVal: TJSONValue;
  itemObj, clashApiObj: TJSONObject;
  sel: TConfigSelector;
  outboundsArr: TJSONArray;
  selectorList: TList<TConfigSelector>;
  inboundType: string;
  listenHost: string;
  listenPort: integer;
  hasMixedInbound: boolean;

  function getStr(const obj: TJSONObject; const name: string; const ADefault: string = ''): string;
  begin
    if not obj.TryGetValue(name, result) then
      result := ADefault;
  end;

begin
  result := Default (TSingBoxConfig);
  hasMixedInbound := false;
  listenHost := '';
  listenPort := 0;

  normalizedJson := NormalizeJson(jsonText);
  rootValue := TJSONObject.ParseJSONValue(normalizedJson);
  if rootValue = nil then
    raise Exception.Create('Configuration is corrupted or contains invalid JSON.');

  try
    if not(rootValue is TJSONObject) then
      raise Exception.Create('Configuration root is not a JSON object.');

    rootObj := rootValue as TJSONObject;

    if rootObj.TryGetValue('inbounds', itemsArr) then
    begin
      for itemVal in itemsArr do
      begin
        if not(itemVal is TJSONObject) then
          continue;
        itemObj := itemVal as TJSONObject;

        inboundType := getStr(itemObj, 'type');

        if SameText(inboundType, 'tun') then
        begin
          result.hasTunInbound := true;
          continue;
        end;

        if SameText(inboundType, 'mixed') then
        begin
          hasMixedInbound := true;
          listenHost := getStr(itemObj, 'listen');
          listenPort := StrToIntDef(getStr(itemObj, 'listen_port'), 0);
        end
        else if SameText(inboundType, 'http') then
        begin
          result.hasHttpInbound := true;
          if not hasMixedInbound then
          begin
            listenHost := getStr(itemObj, 'listen');
            listenPort := StrToIntDef(getStr(itemObj, 'listen_port'), 0);
          end;
        end;
      end;
    end;

    result.proxyHost := listenHost;
    result.proxyPort := listenPort;
    if (result.proxyHost = '') and (result.proxyPort > 0) then
      result.proxyHost := '127.0.0.1';

    if rootObj.TryGetValue('outbounds', itemsArr) then
    begin
      selectorList := TList<TConfigSelector>.Create;
      try
        for itemVal in itemsArr do
        begin
          if not(itemVal is TJSONObject) then
            continue;
          itemObj := itemVal as TJSONObject;

          if SameText(getStr(itemObj, 'type'), 'selector') then
          begin
            sel := Default (TConfigSelector);
            sel.name := getStr(itemObj, 'tag');
            sel.defaultName := getStr(itemObj, 'default');
            sel.defaultIndex := -1;

            if itemObj.TryGetValue('outbounds', outboundsArr) then
            begin
              SetLength(sel.outbounds, outboundsArr.Count);
              for outboundI := 0 to outboundsArr.Count - 1 do
              begin
                if outboundsArr.Items[outboundI] is TJSONString then
                  outboundName := TJSONString(outboundsArr.Items[outboundI]).Value
                else
                  continue;

                sel.outbounds[outboundI] := outboundName;
                if sel.defaultName = outboundName then
                  sel.defaultIndex := outboundI;
              end;
            end;

            if Length(sel.outbounds) > 0 then
              selectorList.Add(sel);
          end;
        end;

        result.selectors := selectorList.ToArray;
      finally
        selectorList.Free;
      end;
    end;

    // clash_api is only *read*. It is never created or completed: the selector
    // UI depends on the user's config, not the other way around.
    result.clashApi.externalController := '';
    result.clashApi.secret := '';
    if rootObj.TryGetValue('experimental.clash_api', clashApiObj) then
    begin
      clashApiObj.TryGetValue('external_controller', result.clashApi.externalController);
      clashApiObj.TryGetValue('secret', result.clashApi.secret);
    end;
  finally
    rootValue.Free;
  end;
end;

function HasUsableProxyInbound(const cfg: TSingBoxConfig): boolean;
begin
  result := (cfg.proxyHost <> '') and (cfg.proxyPort > 0);
end;

end.
