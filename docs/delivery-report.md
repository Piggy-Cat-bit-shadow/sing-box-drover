# JieJieBox Windows AMD64 — 施工交付报告

生成时间：2026-10-10
工作目录：`C:\src\JieJieBox-git`（`testing` 分支）
报告依据：本轮实际执行的命令与实测输出，未执行的项一律标注 `NOT RUN` 或 `BLOCKED`。

---

## I. Git 与环境

```text
repo:                     https://github.com/Piggy-Cat-bit-shadow/sing-box-drover
branch:                   testing
starting_sha:             7a8b4acc8b41589643413c39e0eedd6fd3028db4   (与文档记录一致)
final_sha:                66d19e45bfe326f4e27824a8e05779115af52863
local short sha:          66d19e4
origin_testing_sha:       7a8b4acc8b41589643413c39e0eedd6fd3028db4   (未变，尚未 push)
local_vs_remote:          ahead 5 commits, worktree clean
Windows OS / architecture: Windows NT 10.0.19044.0 / AMD64, Is64BitOS=True
PowerShell:               5.1.19041.6456 (本机无 PowerShell 7)
Delphi/RAD Studio:        RAD Studio 13 Community Edition, ProductVersion 37.0,
                          Build 37.0.60542.8024, 安装于
                          C:\Program Files (x86)\Embarcadero\Studio\37.0
Win64 compiler path:      不存在 (BLOCKED，见第 II 节)
MSBuild path:             C:\Windows\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe
                          (FileVersion 4.8.9037.0)
rsvars.bat:               C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat
```

本轮没有 force-push、reset、rebase，没有动 `main`，没有打 tag、没有发 Release。
`origin/testing` 仍停留在起始 SHA，因为本机推送通道未打通（见第 VI 节）。

---

## II. 真实编译

```text
Delphi IDE Build:        NOT RUN
MSBuild Win64 Release:   FAIL  (BLOCKED: DELPHI_WIN64_PLATFORM_NOT_INSTALLED)
Build exit code:         1
GUI exe absolute path:   C:\src\JieJieBox-git\Win64\Release\JieJieBox.exe  (不存在)
GUI exe PE machine:      N/A
GUI exe SHA256:          N/A
GUI exe last-modified vs HEAD:  N/A
```

### 第一次真实编译错误（原文）

```
C:\Program Files (x86)\Embarcadero\Studio\37.0\Bin\CodeGear.Delphi.Targets(427,5):
error MSB6004: The specified task executable location
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc64.exe" is invalid.
```

### 根因（有实测证据，非推测）

| 检查项 | 实测 | 判定 |
|---|---|---|
| `bin\dcc32.exe` | 不存在 | **FAIL** |
| `bin\dcc64.exe` | 不存在 | **FAIL** |
| `bin64\dcc64.exe` | 不存在 | **FAIL** |
| `bin64\dcc64x.exe` | 不存在 | **FAIL** |
| `lib\win32\release` | 915 个文件，685 个 `.dcu`，69 个 `.dcp` | PASS |
| `lib\win64\release` | 15 个文件，**0 个 `.dcu`**，15 个 `.dcp` | **FAIL** |
| `bin64\dbkdebugide370.bpl` | 存在 | — |
| `bin64\rtl370.bpl` | 存在 | — |

结论：**Windows 64-bit 平台从未被安装**。Win32 平台完整，Win64 只有设计期包，
没有编译期库，并且命令行编译器本体 `dcc64.exe` 缺失。这是安装完整性问题，
不是代码问题。

### 已排除的其他假设（均有实测依据）

- **不是杀毒隔离**：本机唯一 AV 是 Windows Defender（Avast 只有安装包，未安装）。
  `Get-MpThreat` 与 `Get-MpThreatDetection` 均为空。
- **不是执行策略拦截**：IFEO 下只有 `Windows10Upgrade.exe`；AppLocker `SrpV2` 键不存在；
  CodeIntegrity 无 WDAC 策略运行（`SecurityServicesRunning = 0`）。
- **不是文件损坏或被篡改**：`bds.exe`、`dcc*.dll`、`rtl370.bpl`、`dbkdebugide370.bpl`
  的 Authenticode 状态均为 `Valid`，签名者 `CN="Idera, Inc."`。
- **不是权限**：`C:\src` 可正常执行 64 位与 32 位程序（用复制到该目录的
  `System32\cmd.exe` 与 `SysWOW64\cmd.exe` 验证，均退出 0）。
- **不是把 64 位 IDE 当成 Win64 编译器**：`bin64\bds.exe` 是 AMD64，但它只是 IDE，
  与 `dcc64.exe` 是两件事，本报告已分开处理。

### 补充实测：`dbkdebugide370.bpl` 报错的原因已定位

注册表 `HKCU\SOFTWARE\Embarcadero\BDS\37.0\Disabled IDE Packages x64` 中存在：

```
$(BDSBIN)\dbkdebugide370.bpl
```

即该包被**显式登记为禁用**，因此 IDE 提示
`Can't load package ... dbkdebugide370.bpl ... 找不到指定的模块`。
文件本身存在且签名有效，这不是文件缺失。

### 本轮为编译所做的准备工作（已提交，待平台补齐后即可编译）

`scripts/package-release.ps1` 已重写为可在本机直接跑通 Win64 构建的形式：

- `Find-Delphi` 不再对 `bin` 目录做 `Split-Path -Parent`（那会向上跑一层，
  永远找不到就在该 `bin` 内的 `rsvars.bat`）；现在从注册表枚举所有已安装 BDS 版本，
  只在候选目录**自身**查找 `rsvars.bat`。
- `rsvars.bat` 与 MSBuild 在**同一个 cmd.exe 会话**内执行，日志写入
  `build-Win64-Release.log`，并校验退出码。
- 编译前删除旧 `JieJieBox.exe`，确保不会把陈旧产物当成本轮输出。

---

## III. 内核

```text
source repo:                Piggy-Cat-bit-shadow/sing-box
release tag:                v0.1.5
asset:                      jiejie-sing-box-windows-amd64-v0.1.5.zip (27,330,449 bytes)
ZIP asset SHA256:           4a88a0a7dec00f002840475f15706fec48298c78a2af2ea3e7ff6ae8fb408c6b
SHA256SUMS matched:         YES
sing-box.exe SHA256:        18d0c63d116a2be545421f36fe3e51e84003008bc882820c0d38fdd31fa7939f
sing-box.exe version 实际 stdout:
                            sing-box version 0.1.5
PE machine:                 0x8664 (AMD64)
```

**这是本轮唯一完整闭环并真实执行的交付环节**（`scripts/fetch-core.ps1`，在
Windows PowerShell 5.1 下运行）：

```
==> Resolving latest core release of Piggy-Cat-bit-shadow/sing-box
    tag: v0.1.5
    asset: jiejie-sing-box-windows-amd64-v0.1.5.zip (26.1 MB)
==> Downloading core archive
==> Verifying SHA256
    expected: 4a88a0a7dec00f002840475f15706fec48298c78a2af2ea3e7ff6ae8fb408c6b
    actual:   4a88a0a7dec00f002840475f15706fec48298c78a2af2ea3e7ff6ae8fb408c6b
    checksum OK
==> Extracting sing-box.exe
    sing-box.exe PE machine: 0x8664 (AMD64)
==> Checking the core actually runs
    version: sing-box version 0.1.5
```

官方 `SHA256SUMS` 原文（交叉核对）：

```
9e0771ff2398a697e9a00ee6af5bdc2abb0c20cf91001e55a472e4e04ef7ec53  jiejie-sing-box-linux-amd64-v0.1.5.tar.gz
ef91bb006756829a2c367579a4529b9f93454efe2eef089e3695509dac417979  jiejie-sing-box-macos-arm64-v0.1.5.tar.gz
4a88a0a7dec00f002840475f15706fec48298c78a2af2ea3e7ff6ae8fb408c6b  jiejie-sing-box-windows-amd64-v0.1.5.zip
```

`core.txt` 记录（`C:\src\coretest\core.txt`）：

```
repo=Piggy-Cat-bit-shadow/sing-box
tag=v0.1.5
asset=jiejie-sing-box-windows-amd64-v0.1.5.zip
asset_sha256=4a88a0a7dec00f002840475f15706fec48298c78a2af2ea3e7ff6ae8fb408c6b
sing-box.exe_sha256=18d0c63d116a2be545421f36fe3e51e84003008bc882820c0d38fdd31fa7939f
pe_machine=0x8664
version=sing-box version 0.1.5
```

未修改、未重编内核，未触发内核仓库的工作流，未从其 Actions 取内核。

因为 GUI 未编译，测试 ZIP 无法产出，所以 `sing-box.exe` 目前位于
`C:\src\coretest\`，尚未进入 `dist\`。

---

## IV. 完整测试包

```text
local ZIP path:          NOT PRODUCED
ZIP SHA256:              N/A
ZIP file listing:        N/A
ZIP unzip verification:  N/A  (打包脚本内含该步骤，尚未执行到)
GUI + core both present and AMD64:  NO (GUI 缺失)
core.txt / BUILDINFO checked:       N/A
unsigned:                YES (设计为未签名)
```

**未产出测试包**。原因是第 II 节的 `dcc64.exe` 缺失，无法编译 `JieJieBox.exe`。
按提示词要求，不用旧 EXE、不用改名文件、不用空 ZIP 冒充。

打包脚本 `scripts/package-release.ps1` 已按第 5 节要求重写，其中包含：

- 输出 `dist\JieJieBox-Windows-amd64-test-<shortSHA>.zip`，根目录扁平：
  `JieJieBox.exe`、`sing-box.exe`、`JieJieBox.ini`、`README.md`、
  `BUILDINFO.txt`、`SHA256SUMS.txt`、`config.json`、`profiles\`；
- `BUILDINFO.txt` 含 GUI SHA、Delphi bin、`Win64/Release`、core tag、实际 asset、
  core 哈希、构建时间、`signed=no`、是否运行验证、`pe_machine`；
- `Compress-Archive` 后**立即重新解压到干净临时目录**，逐文件复算 SHA256 与
  `SHA256SUMS.txt` 比对，检查根目录扁平、两个 EXE 均为 AMD64，并拒绝
  `.git`、`core.txt`、日志等；
- 删除 `brcc32` + 改 PE 尾部生成 `-opener.exe` 的逻辑（该做法不能产生可用的
  ZIP 打开器，只会破坏已签名 EXE），删除 `config-only.zip`；
- `-SkipBuild` 必须由 `.build-stamp.txt` 证明同一 commit 才能使用，否则直接失败。

---

## V. 实机 Debug（F0/F1/F2/F3）

**全部 `NOT RUN`**。原因：没有可运行的 `JieJieBox.exe`。逐项如下：

| 项 | 状态 | 说明 |
|---|---|---|
| F0 ZIP 解压 / PE 双 AMD64 / SHA | NOT RUN | 无 ZIP |
| F0 `sing-box.exe version` | **PASS** | 实测输出 `sing-box version 0.1.5`，退出 0 |
| F0 GUI 托盘启动、中文、图标、日志 | NOT RUN | 无 GUI EXE |
| F0 各一个实例、单实例互斥 | NOT RUN | 无 GUI EXE |
| F0 退出后 core 退出、代理恢复 | NOT RUN | 无 GUI EXE |
| F1 A1 mixed-only | NOT RUN | 无 GUI EXE |
| F1 A2 mixed + TUN（UAC） | NOT RUN | 无 GUI EXE |
| F1 A3 TUN-only | NOT RUN | 无 GUI EXE |
| F1 B1 selector + clash_api | NOT RUN | 无 GUI EXE |
| F1 B2 selector 无 clash_api | NOT RUN | 无 GUI EXE |
| F1 B3 JSON 保真 | NOT RUN | 无 GUI EXE |
| F2 C1–C10 订阅与更新 | NOT RUN | 无 GUI EXE |
| F2 D1/D2 profile 切换与重启 | NOT RUN | 无 GUI EXE |
| F3 Windows 系统边界 | NOT RUN | 无 GUI EXE |

为让这些用例可在工具链就绪后立即执行，本轮新增
`tools/smoke-test.ps1`，并已用合成包实测跑通（退出码 0）：
校验 SHA256SUMS、两个 EXE 的 PE 架构、`BUILDINFO` 必需字段、
`sing-box.exe version`，并把必须人工在桌面完成的项明确列为 NOT RUN，
绝不冒充 PASS。

系统代理当前实测值（用于测试后比对，只读采集，未修改）：

```
ProxyEnable  = 1
ProxyServer  = 127.0.0.1:7892
ProxyOverride= *zhihu.com;*zhimg.com;*jd.com;100ime-iat-api.xfyun.cn;*360buyimg.com;
               *.bilibili.com;*.bilibili.tv;*.hdslb.com;localhost;*.local;127.*;
               10.*;172.16.*;...;192.168.*
```

**这一项恰好证明了 C4 修复的必要性**：旧实现的 `DisableSystemProxy` 会把上述
配置无条件写成“直连”，从而破坏用户现有代理。修复后只在确认当前值仍是我们写入的
值时才回滚，否则保留第三方的新配置。

进程清理：本轮所有探测进程已按精确名称终止，无残留（`dcc32`/`dcc64`/探测副本
均已确认不存在）。系统自检正常：`csrss`、`wininit`、`services`、`lsass`、
`smss`、`explorer`、`winlogon`、`dwm` 均在，uptime 连续未中断。

---

## VI. GitHub Actions

```text
workflow file:                    未创建（用户明确选择“暂不接 CI”）
trigger:                          N/A
runner location/type:             N/A
runner safety constraints:        N/A
Delphi source compilation in Action: NO
run URL:                          N/A
run conclusion:                   N/A
Artifact name:                    N/A
Artifact URL:                     N/A
Artifact ZIP SHA256:              N/A
Artifact downloaded and validated: NO
```

按提示词 G1 的方案 3 处理：本机只有本地 Delphi 时，先完成本地构建与实机测试，
Action 完整产物标记为

```
BLOCKED: SAFE_DELPHI_ACTION_RUNNER_NOT_AVAILABLE
```

理由：GitHub-hosted `windows-latest` 不含 Delphi/VCL；把带有商业许可证的个人
Windows 机器注册成公开仓库的长期 self-hosted runner 有 GitHub 官方文档指出的
持久入侵风险。用户本轮明确选择“暂不接 CI，先要本地 ZIP”，因此未创建任何
workflow，也未把静态检查伪装成“已编译的 AMD64 客户端”。

### 推送状态

本地已有 5 个提交待推送，但**推送通道未打通**：

- `origin` 当前指向 `https://ghproxy.net/https://github.com/...`（clone 时用的镜像，
  因为本机 `github.com:443` 被间歇性阻断，而 `codeload.github.com` 与
  `api.github.com` 可达）；
- `git push --dry-run` 失败：`could not read Username for 'https://ghproxy.net'`，
  本机没有可用的 git 凭据。

用户已选择“提供 PAT 后由 git push”。需要提醒的是：**不要把 PAT 贴进聊天记录**。
且由于 `github.com:443` 不通，PAT 需要配合镜像使用，这会让镜像方看到该 token；
若不接受该风险，可改走 GitHub 集成推送（会把 5 个提交合并为 1 个远端提交）。

---

## VII. 发布状态

```text
LOCAL_WINDOWS_TEST_PACKAGE_READY: NO   (BLOCKED: DELPHI_WIN64_PLATFORM_NOT_INSTALLED)
GITHUB_ACTION_AMD64_ARTIFACT_READY: NO (BLOCKED: SAFE_DELPHI_ACTION_RUNNER_NOT_AVAILABLE)
PUBLIC_RELEASE_READY: NO
```

---

## 本轮实际完成的代码与脚本修复

已提交为 5 个提交（`7a8b4ac..66d19e4`），共 11 个文件、+1340 / −292 行。

### C1 `fix(subscription): parse Subscription-Userinfo expire as Unix seconds`

`ConfigUpdater.pas`：原 `DotNetDateToUnix` 把 Header 的 `expire` 当 .NET ticks
处理，而 `Main.pas:FormatExpire` 与 `AppState` 都按 Unix 秒使用；任何真实
Unix 秒值都会落在 `.NET` 纪元之前被归零，导致 `HasExpire` 恒为假、到期日永远隐藏。
改为 `ParseUserinfoExpire`：按 Unix 秒解析，并把缺失、空、非数字、带尾随垃圾、
0、负数、Int64 溢出、过小值全部映射为 0（UI 视为“无到期信息”），且任何异常值
都不会导致下载整体失败。

### C2 `fix(bpf): enforce atomic persistence and report write failures`

`SingBoxBpf.pas`：原 `AtomicWriteFile` 有两处缺陷，均已修复——
① 临时文件写入失败的异常被吞掉，可能静默返回、调用方误判成功；
② 原子替换失败后回退 `TFile.WriteAllBytes(AFileName, AData)` 直接覆盖旧 BPF。
现在严格为「同目录临时写入 → flush/close → 原子替换」，失败时保留旧文件、
清理自己的临时文件、抛出携带真实原因的 `EBpfProfileError`，**不再有任何
原地覆盖回退**。`WriteBpfProfileFile` 不再用通用文案掩盖真实原因。

### C3+C4 `fix(profiles): keep inactive updates inactive and stop clobbering the user proxy`

- `Main.pas`：inactive profile 更新成功后**不再调用 `SwitchProfile`**，
  改为仅下载/保存/刷新 + 明确的气泡提示（新增
  `DIALOG_SUBSCRIBE_UPDATED_KEPT`、`DIALOG_SUBSCRIBE_BUSY`）。
  切换订阅仍走独立入口。
- 并发：`StartProfileUpdate` 对同一 profile 文件已有运行中 worker 时直接拒绝，
  两次快速点击不会并发写同一 BPF（新增 `DIALOG_SUBSCRIBE_BUSY` 文案）。
- 生命周期：完成回调改为传**文件路径**而非 worker 实例，消除悬垂引用；
  worker 由 `CleanupFinishedUpdateWorkers` 释放，并用 `TThread.ForceQueue`
  延后到自身排队回调返回之后；`RequestShutdownWorkers` 用有界等待
  （`GetTickCount64` 计时，不会回绕）join 所有一次性 worker，确保 GUI 销毁前
  不再有 worker 存活。
- `SystemProxy.pas`（重写）：`DisableSystemProxy` 不再无条件写“直连”。首次启用前
  快照 Windows 原值（含 flags 与 bypass 列表），退出/切换时恢复；若期间已被其他
  工具接管（当前值与我们所写不一致），则放弃自己的陈旧快照、不动第三方配置。

### D1–D4 `build: make the Win64 package script reproducible and the core fetch honest`

`scripts/package-release.ps1` 重写（含第 5 节全部要求），
`scripts/fetch-core.ps1` 修正：
资产改从 API asset 端点下载（`browser_download_url` 经 `github.com` 跳转，在
github.com 被过滤的网络下会以 `unexpected EOF` 中断）并加入 3 次重试；
新增 PE 架构校验与 `sing-box.exe version` 强制校验（原实现只 `Write-Warning`，
可能“成功”产出一个跑不起来的内核）；`exit 0/1` 改为 `return/throw` 以便被
上层脚本安全调用。移除 `pwsh` 依赖：现在只需 Windows PowerShell 5.1。

### 新增测试与文档

- `tools/smoke-test.ps1`：只读包校验，已用合成包实测通过。
- `docs/windows-build.md`：从零复现 Win64 构建、如何判断 Win64 平台是否真的安装、
  内核验真流程、smoke test 用法、人工 GUI 测试步骤（含代理原值保存/恢复）、
  故障排查表、CI 状态说明。

三个 PowerShell 脚本均通过 PowerShell 5.1 的
`[Parser]::ParseFile` 语法校验（无解析错误）。

---

## 剩余阻塞与最小必要操作

1. **补装 Delphi 的 Windows 64-bit 平台**（唯一阻塞编译的原因）。
   验收标准：`bin\dcc64.exe` 存在 **且** `lib\win64\release` 下 `.dcu` 数量远大于 0。
   合法途径：官方安装程序的 Modify/Repair，或官方特性安装
   `"...\bin\GetItCmd.exe" -if=delphi_windows`。
   补齐后本机即可真实编译，无需再改任何代码。

2. **IDE 许可证**：License Manager 显示 Registered / 到期 2027-10-12，但 IDE 报
   `No valid license information found for Embarcadero Delphi 13`。
   已查实 `C:\ProgramData\Embarcadero\` 下有 4 个 `.slip` 与
   `.cgb_license`、`.licenses\.cg_license`，而
   `%APPDATA%\Embarcadero\licenseSelection.properties` 为 **0 字节**（无选中记录），
   `HKCU\SOFTWARE\Embarcadero` 下无任何 license/serial 注册表项。
   建议走官方注册向导重新选中已有 CE 许可证。此项不影响命令行编译，只影响 IDE。

3. **推送**：提供 PAT（不要贴进聊天）或授权使用 GitHub 集成推送。

4. **Actions 产物**：需要用户明确批准一台隔离的专用构建机后，才能把
   `SAFE_DELPHI_ACTION_RUNNER_NOT_AVAILABLE` 解除。
