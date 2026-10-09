unit SubscriptionManager;

// Deliberately tiny profile store: a `profiles\` folder full of `.bpf` files.
// No database, no repository abstractions. A `.bpf` file already carries
// everything a subscription needs (name, URL, interval, last update time), so
// it *is* the subscription object.

interface

uses
  System.SysUtils, SingBoxBpf;

type
  TSubscriptionProfile = record
    filePath: string;
    name: string;
    remotePath: string;
    autoUpdate: boolean;
    autoUpdateInterval: int32;
    lastUpdated: int64;
    profileType: int32;
  end;

  TProfileList = TArray<TSubscriptionProfile>;

  TSubscriptionManager = class
  public
    // Returns the `profiles\` folder next to the executable, creating it when
    // missing. Returns an empty string when the folder cannot be created.
    class function EnsureProfilesDir(const AAppDir: string): string; static;
    class function BuildProfilePath(const AProfilesDir, AName: string): string; static;
    class function SanitizeFileName(const AName: string): string; static;

    class function List(const AProfilesDir: string): TProfileList; static;
    class function Load(const AFilePath: string): TSubscriptionProfile; static;
    class function Write(const AFilePath: string; const AProfile: TBpfProfile): boolean; static;
    class function Delete(const AFilePath: string): boolean; static;

    // True when AProfilePath and AActivePath point at the same file. Empty and
    // missing paths never match.
    class function SamePath(const AProfilePath, AActivePath: string): boolean; static;

    // Stores AFilePath relative to AAppDir when it lives underneath it (so the
    // saved state survives moving the whole folder), otherwise absolute.
    class function ToStoredPath(const AFilePath, AAppDir: string): string; static;
    class function FromStoredPath(const AStoredPath, AAppDir: string): string; static;
  end;

implementation

uses
  System.IOUtils, System.Classes;

const
  PROFILES_DIR_NAME = 'profiles';
  BPF_EXTENSION = '.bpf';
  FALLBACK_PROFILE_NAME = 'subscription';
  // Characters Windows rejects in a file name.
  //
  // This must be a set, not an array: CharInSet requires a TSysCharSet, and the
  // previous array declaration means this line could never have compiled.
  INVALID_FILE_CHARS: TSysCharSet = ['<', '>', ':', '"', '/', '\', '|', '?', '*'];
  // Device names that are illegal as a file name base on Windows.
  RESERVED_NAMES: array [0 .. 21] of string = ('CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9');

class function TSubscriptionManager.EnsureProfilesDir(const AAppDir: string): string;
var
  dir: string;
begin
  result := '';
  if AAppDir = '' then
    exit;

  dir := IncludeTrailingPathDelimiter(AAppDir) + PROFILES_DIR_NAME;
  try
    if not TDirectory.Exists(dir) then
      TDirectory.CreateDirectory(dir);
    result := dir;
  except
    result := '';
  end;
end;

class function TSubscriptionManager.SanitizeFileName(const AName: string): string;
var
  i, k: integer;
  c: char;
  sb: TStringBuilder;
  candidate: string;
  reserved: boolean;
begin
  sb := TStringBuilder.Create;
  try
    for i := 1 to Length(AName) do
    begin
      c := AName[i];
      if Ord(c) < 32 then
        continue;
      if CharInSet(c, INVALID_FILE_CHARS) then
        continue;
      sb.Append(c);
    end;

    candidate := trim(sb.ToString);
  finally
    sb.Free;
  end;

  // Windows also rejects names ending with a dot or a space.
  while (candidate <> '') and CharInSet(candidate[Length(candidate)], ['.', ' ']) do
    candidate := Copy(candidate, 1, Length(candidate) - 1);

  if (candidate = '') or (candidate = '.') or (candidate = '..') then
    candidate := FALLBACK_PROFILE_NAME;

  reserved := false;
  for k := Low(RESERVED_NAMES) to High(RESERVED_NAMES) do
    if SameText(candidate, RESERVED_NAMES[k]) then
    begin
      reserved := true;
      break;
    end;

  if reserved then
    candidate := '_' + candidate;

  // Guard against a pathological length (leaves room for the " (nn)" suffix).
  if Length(candidate) > 80 then
    candidate := Copy(candidate, 1, 80);

  result := candidate;
end;

class function TSubscriptionManager.BuildProfilePath(const AProfilesDir, AName: string): string;
var
  base, candidate: string;
  counter: integer;
begin
  base := SanitizeFileName(AName);

  if AProfilesDir = '' then
    exit(base + BPF_EXTENSION);

  candidate := IncludeTrailingPathDelimiter(AProfilesDir) + base + BPF_EXTENSION;
  counter := 1;
  while TFile.Exists(candidate) and (counter < 999) do
  begin
    inc(counter);
    candidate := IncludeTrailingPathDelimiter(AProfilesDir) + base + ' (' + IntToStr(counter) + ')' + BPF_EXTENSION;
  end;

  result := candidate;
end;

class function TSubscriptionManager.Load(const AFilePath: string): TSubscriptionProfile;
var
  profile: TBpfProfile;
begin
  result := Default (TSubscriptionProfile);
  profile := ReadBpfProfileFromFile(AFilePath);

  result.filePath := AFilePath;
  result.name := profile.name;
  if result.name = '' then
    result.name := TPath.GetFileNameWithoutExtension(AFilePath);
  result.remotePath := profile.remotePath;
  result.autoUpdate := profile.autoUpdate;
  result.autoUpdateInterval := profile.autoUpdateInterval;
  result.lastUpdated := profile.lastUpdated;
  result.profileType := profile.profileType;
end;

class function TSubscriptionManager.List(const AProfilesDir: string): TProfileList;
var
  files: TArray<string>;
  items: TProfileList;
  filePath: string;
  profile: TSubscriptionProfile;
  count, i, j: integer;
  swap: TSubscriptionProfile;
begin
  SetLength(result, 0);
  if (AProfilesDir = '') or (not TDirectory.Exists(AProfilesDir)) then
    exit;

  try
    files := TDirectory.GetFiles(AProfilesDir, '*' + BPF_EXTENSION);
  except
    SetLength(result, 0);
    exit;
  end;

  SetLength(items, Length(files));
  count := 0;
  for filePath in files do
  begin
    try
      profile := Load(filePath);
    except
      // A broken profile must not hide the healthy ones.
      continue;
    end;
    items[count] := profile;
    inc(count);
  end;

  SetLength(items, count);

  // Insertion sort by display name: the list is tiny and this avoids depending
  // on comparer generics.
  for i := 1 to count - 1 do
  begin
    swap := items[i];
    j := i - 1;
    while (j >= 0) and (CompareText(items[j].name, swap.name) > 0) do
    begin
      items[j + 1] := items[j];
      dec(j);
    end;
    items[j + 1] := swap;
  end;

  result := items;
end;

class function TSubscriptionManager.Write(const AFilePath: string; const AProfile: TBpfProfile): boolean;
begin
  result := false;
  try
    WriteBpfProfileFile(AFilePath, AProfile);
    result := true;
  except
    result := false;
  end;
end;

class function TSubscriptionManager.Delete(const AFilePath: string): boolean;
begin
  result := false;
  if (AFilePath = '') or (not TFile.Exists(AFilePath)) then
    exit;

  try
    TFile.Delete(AFilePath);
    result := true;
  except
    result := false;
  end;
end;

class function TSubscriptionManager.SamePath(const AProfilePath, AActivePath: string): boolean;
var
  a, b: string;
begin
  result := false;
  if (AProfilePath = '') or (AActivePath = '') then
    exit;

  try
    a := TPath.GetFullPath(AProfilePath);
    b := TPath.GetFullPath(AActivePath);
  except
    a := AProfilePath;
    b := AActivePath;
  end;

  result := SameText(a, b);
end;

class function TSubscriptionManager.ToStoredPath(const AFilePath, AAppDir: string): string;
var
  full, dir: string;
begin
  if AFilePath = '' then
    exit('');

  try
    full := TPath.GetFullPath(AFilePath);
  except
    exit(AFilePath);
  end;

  if AAppDir = '' then
    exit(full);

  dir := IncludeTrailingPathDelimiter(TPath.GetFullPath(AAppDir));
  if (Length(full) > Length(dir)) and SameText(Copy(full, 1, Length(dir)), dir) then
    result := Copy(full, Length(dir) + 1, MaxInt)
  else
    result := full;
end;

class function TSubscriptionManager.FromStoredPath(const AStoredPath, AAppDir: string): string;
begin
  if AStoredPath = '' then
    exit('');

  if TPath.IsPathRooted(AStoredPath) then
    result := AStoredPath
  else
    result := IncludeTrailingPathDelimiter(AAppDir) + AStoredPath;
end;

end.
