# Building and packaging JieJieBox for Windows x64

This document describes how `JieJieBox.exe` is produced, how the bundled core is
verified, and how to reproduce the unsigned test package from scratch.

Only **Windows x64 / AMD64** is supported. The project is a minimal
Delphi/Object Pascal VCL tray shell; there is no Win32, ARM64, Linux, Android or
Apple target, and no multi-platform matrix.

---

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| Windows 10/11 x64 | Development and test target |
| RAD Studio / Delphi with the **Windows 64-bit** platform | The IDE is not necessary; the command-line toolchain is enough |
| `rsvars.bat` | Ships inside the installation's `bin` directory |
| MSBuild | `.NET Framework` MSBuild is sufficient; `rsvars.bat` also puts its own framework directory on `PATH` |
| PowerShell 5.1 or later | The scripts are written for 5.1 and need no PowerShell 7 |
| Git | Only to obtain the source; the scripts read `.git` directly for the commit SHA |

### Verifying that the Windows 64-bit platform is actually installed

A RAD Studio install can look complete and still be missing the Win64 target, in
which case the build fails with `MSB6004` ("The specified task executable location
...\dcc64.exe is invalid"). Check both of these before building:

```powershell
$bds = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'   # adjust to your version

# 1. the Win64 compiler must exist
Test-Path "$bds\bin\dcc64.exe"

# 2. Win64 must have real compiled units, not just design-time packages
(Get-ChildItem "$bds\lib\win64\release" -Filter *.dcu).Count
```

A healthy install has `dcc64.exe` present and hundreds of `.dcu` files under
`lib\win64\release`. A count of `0` means the platform was never installed, even
if `lib\win32\release` is fully populated - the Win32 platform and the Win64
platform are installed separately.

If either check fails, add the Windows 64-bit platform through the official
Embarcadero installer (Modify / Repair) or, for a supported setup, the official
feature installer:

```powershell
& "$bds\bin\GetItCmd.exe" -if=delphi_windows
```

Do not work around a missing toolchain by renaming another executable, and do not
substitute a previously built `JieJieBox.exe`.

---

## 2. Building from the command line

The scripts live in `scripts/`. `package-release.ps1` performs the whole pipeline.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\package-release.ps1
```

It performs, in order:

1. locate the Delphi installation by looking for `rsvars.bat` in each installed
   BDS version discovered from the registry;
2. run `call rsvars.bat` and MSBuild **in the same `cmd.exe` session** so the
   Delphi environment variables actually reach the build, rebuilding
   `Release`/`Win64` and writing the full log to `build-Win64-Release.log`;
3. fetch and verify the core (`scripts\fetch-core.ps1`, skipped with `-SkipCore`);
4. stage `dist\JieJieBox-Windows-amd64-test-<shortSHA>\`;
5. write `BUILDINFO.txt` and `SHA256SUMS.txt`;
6. zip it, then re-extract the archive into a clean temporary directory and
   verify every recorded hash, the flat root layout, and that both executables
   are AMD64.

### Parameters

| Parameter | Purpose |
|---|---|
| `-Config` | Build configuration, default `Release` |
| `-Platform` | Target platform, must be `Win64` |
| `-Version` | Override the folder/zip version; default comes from the EXE's `VERSIONINFO` |
| `-SkipBuild` | Reuse an existing `Win64\Release\JieJieBox.exe` |
| `-SkipCore` | Reuse an existing `sing-box.exe` |
| `-CoreTag` | Pin a specific core release tag |

`-SkipBuild` is refused unless `.build-stamp.txt` proves the existing EXE was built
from the current `HEAD` in the same session. This exists so a stale binary can
never be packaged as a fresh build.

### Expected output

```
dist\JieJieBox-Windows-amd64-test-<shortSHA>.zip
```

with a flat archive root:

```
JieJieBox.exe        the GUI, built from this commit
sing-box.exe         the verified core
JieJieBox.ini        application settings
config.json          default configuration
README.md
BUILDINFO.txt        GUI commit, Delphi bin, core tag/asset/hashes, PE machine
SHA256SUMS.txt       SHA256 of every file above
profiles\            empty; subscriptions are added from the tray menu
```

The package is **unsigned**. Windows SmartScreen may warn on first launch; that is
expected and must not be worked around by disabling Defender.

---

## 3. Fetching and verifying the core

`scripts\fetch-core.ps1` resolves the *latest* release of
`Piggy-Cat-bit-shadow/sing-box` exactly once, then uses that frozen tag for every
later step so a single build cannot mix two core versions:

1. resolve the release and remember `tag_name`;
2. find the single asset matching `jiejie-sing-box-windows-amd64-*.zip`;
3. download that zip and the release's `SHA256SUMS`;
4. compare the SHA256; a mismatch is a hard failure;
5. extract `sing-box.exe` and check its PE machine is `0x8664` (a hash match does
   not prove the architecture);
6. run `sing-box.exe version` and require exit code 0 and real output;
7. write `core.txt` with the tag, asset name, both hashes and the real version.

The assets are downloaded through the GitHub API asset endpoint rather than
`browser_download_url`. Both serve the same bytes, but the latter redirects
through `github.com/releases/download`, which fails part-way with
"unexpected EOF" on networks where `github.com` is filtered; `api.github.com`
already has to be reachable for the metadata request.

If the release has no Windows amd64 asset, `SHA256SUMS` is missing, the archive is
corrupt, a hash does not match, the PE machine is wrong, or the version command
fails, the whole package fails. The script never falls back to an older release.
Set `GITHUB_TOKEN` to avoid API rate limits; a pinned tag may be passed with
`-CoreTag`.

---

## 4. Running the smoke test

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\smoke-test.ps1 `
    -ZipPath .\dist\JieJieBox-Windows-amd64-test-<shortSHA>.zip
```

It extracts the archive into a clean temporary directory and checks the recorded
hashes, the PE architecture of both executables, the `BUILDINFO.txt` fields, and
that `sing-box.exe version` runs. GUI behaviour (tray icon, Chinese text,
single-instance guard, core termination, proxy restoration) has to be observed by
hand; the script lists those as NOT RUN rather than reporting them as passing.

---

## 5. Testing the GUI by hand

Use a minimal, non-private configuration. Never put a real subscription URL or a
clash API secret into a log, an issue or an artifact.

1. Extract the zip to a **writable** directory. Portable mode needs write access
   next to the EXE; do not place it in `Program Files`.
2. Record the current Windows proxy settings first:
   `HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings`
   (`ProxyEnable`, `ProxyServer`, `ProxyOverride`).
3. Launch `JieJieBox.exe`, confirm the tray icon and status text, and confirm
   Chinese labels render correctly.
4. Confirm one `JieJieBox.exe` and one `sing-box.exe`, and that a second launch is
   refused by the single-instance guard.
5. Exit from the tray, confirm `sing-box.exe` terminates, and confirm the proxy
   settings are back to the recorded values.

For a config containing a `tun` inbound, expect exactly one UAC prompt. Declining
it must produce a clear error and exit - never a silent fallback to a TUN-less run.

---

## 6. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `MSB6004: ... dcc64.exe is invalid` | The Windows 64-bit platform is not installed. See section 1. |
| `MSB6003: not a valid application for this OS platform` | The compiler entry point is missing or wrong; the install is incomplete. Reinstall the platform. |
| `lib\win64\release` has 0 `.dcu` files | Only the Win32 platform is installed. |
| `package-release failed: No usable RAD Studio installation detected` | `rsvars.bat` was not found; set `BDS` or install the platform. |
| `-SkipBuild refused: the EXE was built from commit ...` | The existing EXE is stale. Run a full build. |
| `SHA256 mismatch for <asset>` | The core download was corrupted or tampered with. The package is refused; re-run. |
| `unexpected EOF` while downloading the core | `github.com` is filtered on this network. The script already uses the API endpoint; check `api.github.com` reachability. |
| `fetch-core failed: ... 'sing-box.exe version' failed` | The extracted core cannot run. The package is refused. |

---

## 7. Continuous integration status

GitHub-hosted `windows-latest` runners do **not** include Delphi or the VCL, and
the compiler cannot be installed there legally without an appropriately licensed
runner. Enabling a self-hosted runner on a personal machine for a public
repository carries a documented persistent-compromise risk, so no automated Win64
build is configured here.

Consequently, producing the AMD64 artifact inside GitHub Actions is
`BLOCKED: SAFE_DELPHI_ACTION_RUNNER_NOT_AVAILABLE` until an isolated, dedicated
build machine is provided and explicitly approved. Until then the local package
described above is the deliverable, and it must never be described as an Actions
artifact.
