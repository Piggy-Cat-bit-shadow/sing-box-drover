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

> **状态更新（2026-10-10 03:0x）：编译已完成。** 第一次成功的 Win64/Release 构建
> 于 02:56 产出，之后修复了一个单实例缺陷并重新构建。以下保留最初的失败记录作为
> 根因证据，成功结果见 “II-b”。

```text
Delphi IDE Build:        NOT RUN（全程命令行，未使用 IDE）
MSBuild Win64 Release:   PASS（详见 II-b）
```

### II-b 成功构建

```text
Build exit code:         0
编译器:                  C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc64.exe
MSBuild:                 C:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe
配置/平台:               Release / Win64
编译日志:                build-Win64-Release.log（0 errors, 5 warnings）
GUI exe absolute path:   C:\src\JieJieBox-git\Win64\Release\JieJieBox.exe
GUI exe size:            5,837,312 bytes
GUI exe PE machine:      0x8664 (AMD64), optional magic 0x020B (PE32+)
GUI exe VERSIONINFO:     FileVersion 0.1.5.0 / ProductVersion 0.1.5.0
GUI exe SHA256:          记在包内 SHA256SUMS.txt（每次构建都会变）
```

**这是本项目第一次被真正编译**，因此编译器一次性暴露了 9 处静态检查发现不了的缺陷，
全部已修复（提交 `790e88b`）。其中两条最典型：

- `AppStrings.pas` 的 `DIALOG_BAD_URL` 从**第一个提交起**就是断的
  （`' http:` 既没有结束引号也没有分号）。
- `Drover.pas` 的 `TProfileUpdateThread` 只在 implementation 里定义、
  interface 里仅前向声明，导致它所有成员的使用全部退化成“未声明标识符”。

### II-c 资源管线（app.res）

RLINK32 拒绝原先由 `tools/make_app_res.py` 生成的文件，报
`E2161 Unsupported 16bit resource`。现改为：

- `tools/app.rc` 描述资源，由 **brcc32** 编译（与消费它的编译器同源，输出布局必然被
  RLINK32 接受）；
- brcc32 **无法读取 PNG 压缩的图标项**（报 `Allocate failed`），而仓库三个 `.ico`
  的 256×256 项都是 PNG，因此 `tools/prepare-icons.ps1` 先把这些项用
  `System.Drawing` 重编码为 32 位 DIB 到 `tools/icons/`；
- `scripts/package-release.ps1` 在每次构建前自动执行这两步；`make_app_res.py` 已删除，
  `app.res` 与 `tools/icons/` 改为生成产物。

### 第一次真实编译错误（原文，保留作根因证据）

```text
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
local ZIP path:          C:\src\JieJieBox-git\dist\JieJieBox-Windows-amd64-test-bf6fefd.zip
ZIP size:                29,050,658 bytes
ZIP SHA256:              22d9412b71f33dd0ea0a21e9e2d9857734c8568123ed7d9c89b775205a5933a3
ZIP file listing:        BUILDINFO.txt, config.json, JieJieBox.exe, JieJieBox.ini,
                         README.md, SHA256SUMS.txt, sing-box.exe, profiles\README.txt
ZIP unzip verification:  PASS（打包脚本重新解压到干净临时目录，逐文件复算 SHA256 全部匹配）
GUI + core both present and AMD64:  YES（两者 PE machine 均 0x8664）
core.txt / BUILDINFO checked:       PASS（BUILDINFO 六项必需字段齐全，signed=no）
unsigned:                YES
```

`tools/smoke-test.ps1` 对该包实测 **退出码 0，全部已执行检查 PASS**：
8 个条目解压、必需文件齐全、两个 EXE 均为 AMD64、6 个文件 SHA256 全匹配、
BUILDINFO 字段齐全、`sing-box.exe version` 返回 `sing-box version 0.1.5`。

打包脚本 `scripts/package-release.ps1` 按第 5 节要求实现，其中包含：

- 输出 `dist\JieJieBox-Windows-amd64-test-<shortSHA>.zip`，根目录扁平：
  `JieJieBox.exe`、`sing-box.exe`、`JieJieBox.ini`、`README.md`、
  `BUILDINFO.txt`、`SHA256SUMS.txt`、`config.json`、`profiles\`；
- `BUILDINFO.txt` 含 GUI SHA、Delphi bin、`Win64/Release`、core tag、实际 asset、
  core 哈希、构建时间、`signed=no`、是否运行验证、`pe_machine`；
- `Compress-Archive` 后**立即重新解压到干净临时目录**，逐文件复算 SHA256 与
  `SHA256SUMS.txt` 比对，检查根目录扁平、两个 EXE 均为 AMD64，并拒绝
  `.git`、`core.txt`、日志等；
- 构建前自动重建 `app.res`（见 II-c）；
- 删除 `brcc32` + 改 PE 尾部生成 `-opener.exe` 的逻辑（该做法不能产生可用的
  ZIP 打开器，只会破坏已签名 EXE），删除 `config-only.zip`；
- `-SkipBuild` 必须由 `.build-stamp.txt` 证明同一 commit 才能使用，否则直接失败。

---

## V. 实机 Debug（F0/F1/F2/F3）

在真实 Windows 桌面会话中对**打包后的** `bf6fefd` 包做了自动化 smoke 测试。GUI 为
托盘程序、无可见主窗口，因此通过向 `TfrmMain` 窗口 PostMessage 驱动关闭。
以下只写实际观测到的结果；未观测的一律 NOT RUN。

| 项 | 状态 | 实测证据 |
|---|---|---|
| F0 ZIP 解压 / PE 双 AMD64 / SHA | **PASS** | smoke-test 退出 0，见第 IV 节 |
| F0 `sing-box.exe version` | **PASS** | `sing-box version 0.1.5`，退出 0 |
| F0 GUI 启动为托盘程序 | **PASS** | PID 存活，`TfrmMain` 窗口存在（不可见），WS 约 17 MB |
| F0 任务管理器各一个实例 | **PASS** | 1 个 `JieJieBox.exe` + 1 个 `sing-box.exe` 子进程 |
| F0 重复双击被互斥体拒绝 | **PASS**（修复后） | 连续启动 3 次，始终只有 **1** 个进程 |
| F0 退出后 core 一并退出 | **PASS**（首次运行） | WM_CLOSE 后 GUI 与子 core 均在约 2 秒内消失 |
| F0 退出后系统代理恢复 | **PASS** | 见下方 C4 专项 |
| F0 日志无异常 | **PASS** | `JieJieBox.log` 仅 5 行正常启动记录，无异常堆栈 |
| F0 优雅退出可重复性 | **FAIL** | 第二次运行 WM_CLOSE 后 30 秒仍未退出，详见 V-a |
| F1 A1 mixed-only | 部分 PASS | 不提权即可运行；自动设置系统代理；退出恢复。断言“既有 inbound 生效”已由 7899 端口监听证实 |
| F1 A2 mixed + TUN / UAC | NOT RUN | 需要交互式 UAC，未在本轮执行 |
| F1 A3 TUN-only | NOT RUN | 同上 |
| F1 B1 selector + clash_api | NOT RUN | 未构造该配置 |
| F1 B2 selector 无 clash_api | NOT RUN | 未构造该配置 |
| F1 B3 JSON 保真 | **PASS** | 子进程命令行即 `sing-box.exe --disable-color run -c stdin`，配置经 stdin 原样传入，未重序列化落盘 |
| F2 C1–C10 订阅与更新 | NOT RUN | 需要 mock HTTP 服务与订阅，未在本轮执行 |
| F2 D1/D2 profile 切换与重启 | NOT RUN | 未执行 |
| F3 Windows 系统边界 | NOT RUN | 未执行 |

### V-a 本轮新发现且尚未修复的缺陷

**优雅退出不可靠（3 次测试中 1 次成功、2 次失败）。** 三次 WM_CLOSE 测试：

| 包 | 结果 |
|---|---|
| `47373f6` | GUI 与 core 约 2 秒内干净退出，系统代理正确恢复 —— PASS |
| `790e88b` | 30 秒仍未退出，core 仍在，代理未恢复 —— FAIL |
| `bf6fefd` | 同样未退出；6 线程全部 Wait、消息循环仍响应 —— FAIL（最终强制结束） |

失败时进程并未卡死：线程全部处于 Wait 状态、`TfrmMain` 仍响应，说明
`TDrover.Shutdown` 没有返回 true，`BackgroundWorkersFinished` 一直为假。
`JieJieBox.log` 在 `[Core] Process created` 之后**没有任何新记录**——连
`Supervisor stopping...` 都没打印，即 supervisor 线程尚未察觉终止信号。
这指向 `CoreSupervisor.TerminatedSet` / `FQueue.DoShutDown` 与
`TDrover.RequestShutdownWorkers` 之间的交互，需要下一轮专门定位。

这是真实缺陷，**未修复**。测试后已用 `Stop-Process` 精确清理进程，并把系统代理
手工恢复为启动前的 `http://127.0.0.1:7890`。

### C4 专项：系统代理恢复（修复验证成功）

本机启动前的真实代理设置为 `ProxyEnable=1`、`ProxyServer=http://127.0.0.1:7890`。
实测过程：

```text
启动前 : Enable=1  Server=http://127.0.0.1:7890
App 运行时: Enable=1  Server=http=127.0.0.1:7899;https=127.0.0.1:7899;socks=127.0.0.1:7899
退出后 : Enable=1  Server=http://127.0.0.1:7890     <-- 正确还原，未被写成“直连”
```

旧实现会把这一整套写死成“直连”，从而破坏用户自己的代理。修复后只在确认当前值仍是
我们写入的值时才回滚，否则保留第三方的新配置。
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

为让其余用例可在后续立即执行，`tools/smoke-test.ps1` 已用合成包和真实包各实测跑通
一次（退出码 0）：校验 SHA256SUMS、两个 EXE 的 PE 架构、`BUILDINFO` 必需字段、
`sing-box.exe version`，并把必须人工在桌面完成的项明确列为 NOT RUN，绝不冒充 PASS。

进程清理：本轮所有测试进程已按精确 PID 终止，`Get-Process` 与
`Get-CimInstance Win32_Process` 双重确认无 `JieJieBox` / 测试用 `sing-box` 残留，
端口 7899 已释放；系统代理已恢复为启动前的 `http://127.0.0.1:7890`。

---

## VI. GitHub Actions

```text
workflow file:                     .github/workflows/static-validation.yml
trigger:                           push 到 testing；另支持 workflow_dispatch
runner location/type:              GitHub-hosted windows-latest（非 self-hosted）
runner safety constraints:         permissions 仅 contents: read；
                                   无 pull_request / pull_request_target 触发；
                                   无 continue-on-error；无自动 release / tag；单架构
Delphi source compilation in Action: NO（该 runner 不含 Delphi/VCL）
run URL:                           https://github.com/Piggy-Cat-bit-shadow/sing-box-drover/actions/runs/37969151163
run conclusion:                    success（7/7 steps，含 check_pascal.py 通过）
Artifact name:                     static-validation-47373f6a7223203876d24315ce89a5d548d97df6
Artifact URL:                      https://api.github.com/repos/Piggy-Cat-bit-shadow/sing-box-drover/actions/artifacts/11635315286/zip
Artifact ZIP SHA256:               未能取得（见下）
Artifact downloaded and validated: NO
```

该 workflow 已在 push 后**真实运行并成功**：`check_pascal.py` 在 CI 上通过，
说明 Pascal 接口/uses 一致性检查可复现。它是**静态校验**，不编译任何客户端，
其自身头部与上传的 `result-scope.txt` 都写明 `delphi_build = NO`、
`gui_exe = not produced`，避免被误当成“已在 CI 编译”。

**Artifact 未下载验证的原因**：GitHub 对 Actions artifact 的 zip 下载接口即使对公开仓库
也要求认证，匿名请求返回 `401 Requires authentication`，本轮无可用 token。
只读的 API 已确认该 artifact 存在（名称、700 bytes、`expired=false`）。

按提示词 G1 的方案 3，**AMD64 客户端**在 Actions 中的构建仍标记为：

```
BLOCKED: SAFE_DELPHI_ACTION_RUNNER_NOT_AVAILABLE
```

理由：GitHub-hosted `windows-latest` 不含 Delphi/VCL；把带有商业许可证的个人
Windows 机器注册成公开仓库的长期 self-hosted runner 有 GitHub 官方文档指出的
持久入侵风险。静态检查 workflow 已建立并跑绿，但它**不编译任何客户端**，
也未被伪装成“已编译的 AMD64 客户端”。

### 推送状态

**已推送完成。** `origin` 已从 clone 时使用的 ghproxy 镜像改回真实
`https://github.com/Piggy-Cat-bit-shadow/sing-box-drover.git`；`github.com:443` 恢复
可达后，用户确认“推送现在通了”，随后以普通 `git push`（非 force）推送：

```text
origin/testing = bf6fefd253ca75768bf5f11344b570d7b347530a
本地 HEAD      = bf6fefd253ca75768bf5f11344b570d7b347530a（一致）
```

期间未使用 force-push、reset 或 rebase，未改 `main`，未打 tag，未发 Release。

---

## VII. 发布状态

```text
LOCAL_WINDOWS_TEST_PACKAGE_READY: YES
  dist\JieJieBox-Windows-amd64-test-bf6fefd.zip
  sha256 22d9412b71f33dd0ea0a21e9e2d9857734c8568123ed7d9c89b775205a5933a3
  含真实编译的 JieJieBox.exe（AMD64）与已验真内核 sing-box.exe（AMD64, v0.1.5）
  smoke-test.ps1 退出码 0；GUI 实机启动/单实例/core 拉起/代理恢复均已实测
  未签名；尚未在干净机器上复测，且存在 V-a 的优雅退出缺陷

GITHUB_ACTION_AMD64_ARTIFACT_READY: NO
  BLOCKED: SAFE_DELPHI_ACTION_RUNNER_NOT_AVAILABLE
  （静态校验 workflow 已建立并跑绿，但它不编译客户端）

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
