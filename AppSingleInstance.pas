unit AppSingleInstance;

// Process-wide single-instance guard.
//
// The mutex handle is deliberately kept in a unit-level variable for the whole
// process lifetime. The previous implementation made it a local of
// AcquireSingleInstance, so the handle was closed as soon as that function
// returned. With no remaining handles the kernel destroys the mutex object, the
// next launch sees no pre-existing mutex, ERROR_ALREADY_EXISTS is never set, and
// the guard silently stops working - two JieJieBox.exe processes plus two cores
// end up running side by side.
//
// Holding the handle also means the guard is released by the operating system if
// the process dies, which is exactly the wanted behaviour.

interface

// Returns True when this process owns the single-instance mutex.
// waitIfExists: when another instance already holds it, wait up to waitMs for it
// to go away instead of failing immediately (used by the elevated relaunch).
function AcquireSingleInstance(mutexName: string; waitIfExists: boolean; waitMs: cardinal = 10000): boolean;

implementation

uses
  Winapi.Windows,
  System.SysUtils;

function ConvertStringSecurityDescriptorToSecurityDescriptorW(StringSecurityDescriptor: PWideChar;
  StringSDRevision: DWORD; out SecurityDescriptor: PSECURITY_DESCRIPTOR; SecurityDescriptorSize: PULONG): BOOL; stdcall;
  external advapi32 name 'ConvertStringSecurityDescriptorToSecurityDescriptorW';

const
  // Owners: SYSTEM, built-in Administrators, and Authenticated Users. The mutex
  // must be usable from both a normal launch and an elevated relaunch, otherwise
  // the elevated instance would create a *second* mutex and defeat the guard.
  MUTEX_SDDL = 'D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;AU)';

var
  // Intentionally never closed: closing it would destroy the mutex while the
  // process is still running. See the unit comment above.
  GMutexHandle: THandle = 0;

function AcquireSingleInstance(mutexName: string; waitIfExists: boolean; waitMs: cardinal): boolean;
var
  sa: TSecurityAttributes;
  sd: PSECURITY_DESCRIPTOR;
  err: DWORD;
  wr: DWORD;
  mutex: THandle;
begin
  result := false;

  // Already acquired by this process: nothing more to do.
  if GMutexHandle <> 0 then
    exit(true);

  sd := nil;
  if not ConvertStringSecurityDescriptorToSecurityDescriptorW(PWideChar(MUTEX_SDDL), 1, sd, nil) then
    exit(false);

  try
    ZeroMemory(@sa, SizeOf(sa));
    sa.nLength := SizeOf(sa);
    sa.bInheritHandle := false;
    sa.lpSecurityDescriptor := sd;

    mutex := CreateMutex(@sa, true, PChar(mutexName));
    if mutex = 0 then
      exit(false);

    err := GetLastError;

    if err = ERROR_ALREADY_EXISTS then
    begin
      if not waitIfExists then
      begin
        // Not our mutex: this handle must not be kept.
        CloseHandle(mutex);
        exit(false);
      end;

      wr := WaitForSingleObject(mutex, waitMs);
      if not(wr in [WAIT_OBJECT_0, WAIT_ABANDONED]) then
      begin
        CloseHandle(mutex);
        exit(false);
      end;
    end;

    // Ownership acquired: keep the handle open for the life of the process.
    GMutexHandle := mutex;
    result := true;

  finally
    if sd <> nil then
      LocalFree(HLOCAL(sd));
  end;
end;

end.
