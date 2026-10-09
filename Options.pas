unit Options;

interface

uses
  Windows,
  System.SysUtils,
  System.StrUtils,
  IniFiles;

const
  OPTIONS_FILENAME = 'JieJieBox.ini';
  // Pre-rename installs keep working: if the new file is absent the old one is
  // used, and it is never rewritten by the app.
  LEGACY_OPTIONS_FILENAME = 'sing-box-drover.ini';
  SECTION_MAIN = 'JieJieBox';
  // Older ini files used this section name.
  LEGACY_SECTION_MAIN = 'sing-box-drover';

type
  TTunStartMode = (tsmOn, tsmOff);
  TSelectorMenuLayout = (smlAuto, smlFlat, smlNested);

  TDroverOptions = record
    sbDir: string;
    sbConfigFile: string;
    systemProxyAuto: boolean;
    tunStartMode: TTunStartMode;
    selectorMenuLayout: TSelectorMenuLayout;
    selectorPersist: boolean;
    logFile: string;
    iniPath: string;

    class function Load(filename: string): TDroverOptions; static;
  private
    class function ParseTunStartMode(s: string): TTunStartMode; static;
    class function ParseSelectorMenuLayout(s: string): TSelectorMenuLayout; static;
  end;

implementation

class function TDroverOptions.ParseTunStartMode(s: string): TTunStartMode;
begin
  s := trim(LowerCase(s));
  if MatchStr(s, ['off', '0', '']) then
    exit(TTunStartMode.tsmOff)
  else
    exit(TTunStartMode.tsmOn);
end;

class function TDroverOptions.ParseSelectorMenuLayout(s: string): TSelectorMenuLayout;
begin
  s := trim(LowerCase(s));
  if s = 'flat' then
    exit(TSelectorMenuLayout.smlFlat)
  else if s = 'nested' then
    exit(TSelectorMenuLayout.smlNested)
  else
    exit(TSelectorMenuLayout.smlAuto);
end;

class function TDroverOptions.Load(filename: string): TDroverOptions;
var
  s, path, currentDir: string;
  f: TIniFile;
begin
  currentDir := IncludeTrailingPathDelimiter(ExtractFilePath(filename));

  result := Default (TDroverOptions);

  if not FileExists(filename) then
  begin
    path := currentDir + LEGACY_OPTIONS_FILENAME;
    if FileExists(path) then
      filename := path;
  end;
  result.iniPath := filename;

  try
    f := TIniFile.Create(filename);
    try
      with f do
      begin
        s := ReadString(SECTION_MAIN, 'sb-dir', '');
        if s = '' then
          s := ReadString(LEGACY_SECTION_MAIN, 'sb-dir', '');
        if s = '' then
          s := currentDir
        else
          s := IncludeTrailingPathDelimiter(s);
        result.sbDir := s;

        s := ReadString(SECTION_MAIN, 'sb-config-file', '');
        if s = '' then
          s := ReadString(LEGACY_SECTION_MAIN, 'sb-config-file', 'config.json');
        if not s.Contains(':') then
        begin
          for path in [currentDir + s, result.sbDir + s] do
          begin
            if FileExists(path) then
            begin
              s := path;
              break;
            end;
          end;
        end;
        result.sbConfigFile := s;

        // tun-start-mode / system-proxy-auto are accepted but ignored: the
        // config decides TUN and the system proxy now.
        result.tunStartMode := ParseTunStartMode(ReadString(SECTION_MAIN, 'tun-start-mode', ''));
        result.systemProxyAuto := true;
        result.selectorMenuLayout := ParseSelectorMenuLayout(ReadString(SECTION_MAIN, 'selector-menu-layout', ''));
        result.selectorPersist := ReadBool(SECTION_MAIN, 'selector-persist', true);

        s := ReadString(SECTION_MAIN, 'log-file', '');
        if (s <> '') and (not s.Contains(':')) then
        begin
          s := currentDir + s;
        end;
        result.logFile := s;
      end;
    finally
      f.Free;
    end;
  except
  end;
end;

end.
