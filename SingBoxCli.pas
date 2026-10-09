unit SingBoxCli;

interface

uses
  Winapi.Windows, System.SysUtils, System.SyncObjs, Logger;

type
  TSingBoxCli = class
  private
    FCorePath: string;
    FLogger: TLogger;
    FLock: TCriticalSection;
    FVersion: string;
    FVersionChecked: boolean;

    function RunCli(const AArgs: string; ATimeoutMs: DWORD; AMaxOutputBytes: integer;
      out AOutput: string; const AStdinData: string = ''): boolean;
    function FetchVersion: string;
    procedure Log(const AMessage: string);
  public
    constructor Create(const ACorePath: string; ALogger: TLogger);
    destructor Destroy; override;

    function GetVersion: string;

    // Thin wrapper around `sing-box check`. Exactly one of AConfigFile /
    // AConfigJson is used; when a JSON body is supplied it is piped through
    // stdin (`check -c stdin`), which avoids creating temp config files.
    // Returns False when the core rejects the candidate config.
    function CheckConfig(const AConfigJson: string; const AWorkDir: string;
      out AOutput: string; const AConfigFile: string = ''): boolean;
  end;

implementation

constructor TSingBoxCli.Create(const ACorePath: string; ALogger: TLogger);
begin
  FCorePath := ACorePath;
  FLogger := ALogger;
  FLock := TCriticalSection.Create;
end;

destructor TSingBoxCli.Destroy;
begin
  FreeAndNil(FLock);
  inherited;
end;

function TSingBoxCli.GetVersion: string;
var
  justFetched: boolean;
begin
  justFetched := false;
  FLock.Enter;
  try
    if not FVersionChecked then
    begin
      FVersion := FetchVersion;
      FVersionChecked := true;
      justFetched := true;
    end;
    result := FVersion;
  finally
    FLock.Leave;
  end;

  if justFetched then
  begin
    if result <> '' then
      Log('Detected version: ' + result)
    else
      Log('Failed to detect version.');
  end;
end;

function TSingBoxCli.FetchVersion: string;
const
  WAIT_TIMEOUT_MS = 5000;
  MAX_OUTPUT_SIZE = 8192;
  MAX_VERSION_LENGTH = 64;
  VERSION_PREFIX = 'sing-box version ';
var
  outputText, firstLine: string;
  nlPos: integer;
begin
  result := '';

  if not RunCli('version', WAIT_TIMEOUT_MS, MAX_OUTPUT_SIZE, outputText) then
    exit;

  nlPos := Pos(#10, outputText);
  if nlPos > 0 then
    firstLine := copy(outputText, 1, nlPos - 1)
  else
    firstLine := outputText;
  firstLine := trim(firstLine);

  if not firstLine.StartsWith(VERSION_PREFIX) then
    exit;

  result := trim(copy(firstLine, length(VERSION_PREFIX) + 1, MAX_VERSION_LENGTH));
  if length(result) >= MAX_VERSION_LENGTH then
    result := '';
end;

function TSingBoxCli.CheckConfig(const AConfigJson: string; const AWorkDir: string;
  out AOutput: string; const AConfigFile: string): boolean;
const
  CHECK_TIMEOUT_MS = 20000;
  MAX_OUTPUT_SIZE = 16384;
var
  args: string;
begin
  AOutput := '';

  if not FileExists(FCorePath) then
  begin
    AOutput := 'Core executable not found: ' + FCorePath;
    exit(false);
  end;

  args := '';
  if (AWorkDir <> '') and DirectoryExists(AWorkDir) then
    args := '-D "' + ExcludeTrailingPathDelimiter(AWorkDir) + '" ';

  if AConfigFile <> '' then
    result := RunCli(args + 'check -c "' + AConfigFile + '"', CHECK_TIMEOUT_MS, MAX_OUTPUT_SIZE, AOutput)
  else
    result := RunCli(args + 'check -c stdin', CHECK_TIMEOUT_MS, MAX_OUTPUT_SIZE, AOutput, AConfigJson);

  if not result then
    Log('Config check rejected the candidate config.');
end;

function TSingBoxCli.RunCli(const AArgs: string; ATimeoutMs: DWORD; AMaxOutputBytes: integer;
  out AOutput: string; const AStdinData: string): boolean;
const
  TERMINATE_WAIT_MS = 1000;
  STDIN_THREAD_WAIT_MS = 10000;
var
  secAttr: TSecurityAttributes;
  stdoutRead, stdoutWrite, stdinRead, stdinWrite, stdinNull: THandle;
  si: TStartupInfo;
  pi: TProcessInformation;
  cmdLine, workDir: string;
  outputBytes: TBytes;
  bytesRead: DWORD;
  totalBytes: integer;
  savedErrorMode: UINT;
  processStarted: boolean;
  stdinBytes: TBytes;
  stdinHandle: THandle;
  feedHandle: THandle;
  stdinThread: TThread;
  pipeSecAttr: TSecurityAttributes;
  needStdinPipe: boolean;

  procedure SafeCloseHandle(var h: THandle);
  begin
    if (h <> 0) and (h <> INVALID_HANDLE_VALUE) then
      CloseHandle(h);
    h := 0;
  end;

begin
  result := false;
  AOutput := '';

  stdoutRead := 0;
  stdoutWrite := 0;
  stdinRead := 0;
  stdinWrite := 0;
  stdinNull := 0;
  stdinHandle := 0;
  feedHandle := 0;
  stdinThread := nil;
  needStdinPipe := false;
  ZeroMemory(@pi, sizeOf(pi));

  try
    try
      ZeroMemory(@secAttr, sizeOf(secAttr));
      secAttr.nLength := sizeOf(secAttr);
      secAttr.bInheritHandle := true;

      if not CreatePipe(stdoutRead, stdoutWrite, @secAttr, 0) then
        exit;

      if not SetHandleInformation(stdoutRead, HANDLE_FLAG_INHERIT, 0) then
        exit;

      needStdinPipe := AStdinData <> '';
      if needStdinPipe then
      begin
        pipeSecAttr := secAttr;
        if not CreatePipe(stdinRead, stdinWrite, @pipeSecAttr, 0) then
          exit;

        if not SetHandleInformation(stdinWrite, HANDLE_FLAG_INHERIT, 0) then
          exit;

        stdinHandle := stdinRead;
      end
      else
      begin
        stdinNull := CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, @secAttr, OPEN_EXISTING,
          FILE_ATTRIBUTE_NORMAL, 0);
        if stdinNull = INVALID_HANDLE_VALUE then
          exit;
        stdinHandle := stdinNull;
      end;

      ZeroMemory(@si, sizeOf(si));
      si.cb := sizeOf(si);
      si.dwFlags := STARTF_USESTDHANDLES;
      si.hStdInput := stdinHandle;
      si.hStdOutput := stdoutWrite;
      si.hStdError := stdoutWrite;

      if AArgs <> '' then
        cmdLine := format('"%s" %s', [FCorePath, AArgs])
      else
        cmdLine := format('"%s"', [FCorePath]);
      workDir := ExtractFileDir(FCorePath);

      savedErrorMode := SetErrorMode(SEM_FAILCRITICALERRORS or SEM_NOGPFAULTERRORBOX or SEM_NOOPENFILEERRORBOX);
      try
        processStarted := CreateProcess(nil, PChar(cmdLine), nil, nil, true, CREATE_NO_WINDOW, nil,
          PChar(workDir), si, pi);
      finally
        SetErrorMode(savedErrorMode);
      end;
      if not processStarted then
        exit;

      // Parent must close its copies of the child ends so that ReadFile sees
      // EOF once the child exits.
      SafeCloseHandle(stdoutWrite);
      SafeCloseHandle(stdinRead);
      SafeCloseHandle(stdinNull);

      if needStdinPipe then
      begin
        // The config can be larger than the pipe buffer, so feed it from a
        // helper thread while we wait for the process to finish.
        stdinBytes := TEncoding.UTF8.GetBytes(AStdinData);
        feedHandle := stdinWrite;
        stdinWrite := 0;

        stdinThread := TThread.CreateAnonymousThread(
          procedure
          var
            p: PByte;
            remain, written: DWORD;
            h: THandle;
            data: TBytes;
          begin
            h := feedHandle;
            data := stdinBytes;
            try
              try
                if Length(data) = 0 then
                  exit;

                p := @data[0];
                remain := DWORD(Length(data));
                while remain > 0 do
                begin
                  written := 0;
                  if not WriteFile(h, p^, remain, written, nil) then
                    break;
                  if written = 0 then
                    break;
                  inc(p, written);
                  dec(remain, written);
                end;
              except
                // A broken pipe simply means the core stopped reading early.
              end;
            finally
              if (h <> 0) and (h <> INVALID_HANDLE_VALUE) then
                CloseHandle(h);
            end;
          end);
        stdinThread.FreeOnTerminate := false;
        stdinThread.Start;
      end;

      if WaitForSingleObject(pi.hProcess, ATimeoutMs) <> WAIT_OBJECT_0 then
      begin
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, TERMINATE_WAIT_MS);
        exit;
      end;

      setLength(outputBytes, AMaxOutputBytes);
      totalBytes := 0;

      while totalBytes < AMaxOutputBytes do
      begin
        bytesRead := 0;
        if not ReadFile(stdoutRead, outputBytes[totalBytes], DWORD(AMaxOutputBytes - totalBytes), bytesRead, nil) then
        begin
          if GetLastError <> ERROR_BROKEN_PIPE then
            exit;
          break;
        end;
        if bytesRead = 0 then
          break;
        inc(totalBytes, bytesRead);
      end;

      setLength(outputBytes, totalBytes);
      AOutput := TEncoding.UTF8.GetString(outputBytes);
      result := true;
    except
      AOutput := '';
      result := false;
    end;
  finally
    SafeCloseHandle(stdinWrite);
    if Assigned(stdinThread) then
    begin
      WaitForSingleObject(stdinThread.Handle, STDIN_THREAD_WAIT_MS);
      stdinThread.Free;
    end;

    SafeCloseHandle(stdoutRead);
    SafeCloseHandle(stdoutWrite);
    SafeCloseHandle(stdinRead);
    SafeCloseHandle(stdinNull);
    SafeCloseHandle(pi.hProcess);
    SafeCloseHandle(pi.hThread);
  end;
end;

procedure TSingBoxCli.Log(const AMessage: string);
begin
  FLogger.Log('SingBoxCli', AMessage);
end;

end.
