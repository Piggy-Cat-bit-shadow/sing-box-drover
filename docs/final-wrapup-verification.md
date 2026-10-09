# 最终收尾验收报告

日期：2026-10-10
仓库：`Piggy-Cat-bit-shadow/sing-box-drover`（fork of `hdrover/sing-box-drover`）
开工 HEAD：`84e3bb6a1fbef0f924132cfdc34065193f3e0bc8`
最终 HEAD：`b5810f4`（报告时）
工作树：clean

---

## 1. 最终判定

```text
WINDOWS_AMD64_BUILD              = PASS
LOCAL_SMOKE                      = PASS
LIFECYCLE_AND_SUBSCRIPTION_REGRESSION = INCOMPLETE
ACTION_STATIC_VALIDATION         = PASS
ACTION_REAL_DELPHI_BUILD         = BLOCKED
BRANCH_CLEANUP                   = BLOCKED
PUBLIC_REDISTRIBUTION_LICENSE    = NOT_CLEARED
OVERALL_RELEASE_READINESS        = READY_FOR_PRIVATE_TEST
```

`LIFECYCLE_AND_SUBSCRIPTION_REGRESSION = INCOMPLETE` 的原因很具体：
进程生命周期与退出部分全部达标（见 §4.1），但**订阅状态机那一组（50/20/20/20 计数）没有执行**
（见 §4.2）。不把它算作 PASS。

---

## 2. P0-1：一次性订阅 worker 的所有权与重复调度线程

### 2.1 两个缺陷都在源码中得到证实

**缺陷一：自毁线程仍被非拥有列表引用。**
`TProfileUpdateThread` 设 `FreeOnTerminate := True`，线程终止时自毁；而
`TDrover.FUpdateWorkers` 是普通 `TList<TProfileUpdateThread>`（非拥有），之后仍读取
`.Finished`、调用 `Terminate`。这些访问没有保障对象仍然存在。

**缺陷二：一次性下载意外伴生第二个调度线程。**
`TConfigUpdater.Create` 末尾是 `inherited Create(false)`，所以为一次性下载构造 updater
时，**同时**启动了一个针对同一 BPF 的完整自动更新循环；外层 worker 又直接调用
`FUpdater.DownloadProfile`（内部走 `FetchAndStore`）。两个线程可以各自完成
下载 → 校验 → 写盘。60 秒首延迟只是降低碰撞概率，不是设计上的排除。

### 2.2 修复（commit `a6741b1`）

- `FUpdateWorkers` 改为 `TObjectList<TProfileUpdateThread>.Create(True)`（拥有），
  worker 的 `FreeOnTerminate` 改回 `False`。每个 worker 由 `TDrover` 在**主线程**上
  恰好释放一次：要么在完成回调跑完之后由 `CleanupFinishedUpdateWorkers` 释放，
  要么由 `StopUpdateWorkers` 释放。列表只在主线程改动，无需加锁。
- `DetachCallback` 改为 `CancelAndDetach`：置取消标志、丢弃回调、`Terminate`，
  全部在主线程执行，worker 不可能再投递触碰正在销毁 GUI 的回调。
- 新增 `TConfigUpdater.MakeOneShotOnly`：使 `Execute` 在**不装载 interval**的情况下
  直接返回；外层 worker 构造后立刻调用。同时新增 `FFetchLock`，把
  **下载 → 校验 → 提交**整段串行化，任何路径都无法并发写同一文件。

### 2.3 六个必答问题

1. **谁创建/持有/判定结束/释放？** `TDrover.StartProfileUpdate` 创建；
   `TDrover.FUpdateWorkers`（拥有型 `TObjectList`）持有；结束由 `TThread.Finished`
   判定；由 `CleanupFinishedUpdateWorkers` 或 `StopUpdateWorkers` 在主线程释放一次。
   **不再存在对已释放对象读 `.Finished` 的路径**，因为对象在释放前一直由 `TDrover` 拥有。
2. **是否曾意外伴生第二个 `TConfigUpdater.Execute`？** 是，修复前确实会。
   现在一次性 worker 调用 `MakeOneShotOnly`，其调度循环不装载；并且 `FFetchLock`
   保证同一文件不会有并发写事务。
3. **100ms 轮询 + 回调丢失是否仍可能残留？** 不会。完成条件基于 `TThread.Finished`
   而非任何单一通知；`PollShutdown` 可从任一调用方推进；窗口侧 100ms 定时器是独立
   兜底。实测见 §4.1。
4. **第三方接管 / 直连 / 内核缺失各测几次？** 第三方 3/3、直连 5/5、内核缺失 5/5。
   没有任何一项未达标却被写成 PASS。
5. **`main` 是否删除？`default_branch`？** **未删除**。报告时
   `default_branch = main`，`git ls-remote --heads origin` 返回 **2** 条（`main`、`testing`）。
   原因见 §6。
6. **本轮 ZIP 是否从最新 SHA 真编译并在解压后运行？Actions 是否真编译 GUI？**
   ZIP 由 `a6741b1` 真实 Rebuild 产出（该提交含全部源码修复；其后仅新增测试脚本与
   结果记录，不影响二进制），解压后的副本上实机运行。**Actions 没有编译 GUI**，
   仅有静态验证。

---

## 3. 真实编译与产物

```text
Delphi:        RAD Studio 37.0 Enterprise/Architect
Windows:       Windows NT 10.0.19044.0 / AMD64
构建命令:      powershell -File scripts/package-release.ps1 -Config Release -Platform Win64
compiler errors: 0
GUI EXE:       Win64\Release\JieJieBox.exe, 5,837,312 bytes
               PE32+ machine 0x8664, VERSIONINFO 0.1.5.0
core:          Piggy-Cat-bit-shadow/sing-box tag v0.1.5
               asset jiejie-sing-box-windows-amd64-v0.1.5.zip
               asset sha256 4a88a0a7…408c6b（与同 Release 的 SHA256SUMS 逐字一致）
               sing-box.exe sha256 18d0c63d…7939f, PE 0x8664
               `sing-box version 0.1.5`
package:       C:\src\JieJieBox-git\dist\JieJieBox-Windows-amd64-test-a6741b1.zip
               29,051,247 bytes
               sha256 a3393d4af242ddda76f9ccdba9c716c72b2c393b49d55072fc7bee298e5fb1c9
内容:          JieJieBox.exe / sing-box.exe / config.json / JieJieBox.ini /
               profiles\ / BUILDINFO.txt / SHA256SUMS.txt / README.md
```

重解压到独立目录后逐文件复算 SHA256：全部一致（`smoke-test.ps1` 退出码 0）。
在该解压副本上完成 6 次以上 GUI 启动/关闭实测（§4.1 的 20 次与 12 次循环均使用副本）。

---

## 4. 测试结果（按 Gate）

### 4.1 已完成并有实测证据

| 测试项 | 目标 | 实际 | 证据 |
|---|---:|---|---|
| 精确 `WM_CLOSE` 退出 | 20 | **20/20 PASS** | `r-a6741b1-wmclose20.json`，app 侧 102–122 ms |
| 启动中立即关闭 | 10 | **10/10 PASS** | `r-a6741b1-startup10.json` |
| 连续重复请求退出 | 10 | **10/10 PASS** | `r-a6741b1-repeat10.json` |
| 原代理非空（`127.0.0.1:7890`） | 5 | **5/5 PASS** | `r-a6741b1-proxy5.json` |
| 原代理为直连 | 5 | **5/5 PASS** | `r-a6741b1-direct5.json` |
| 第三方代理接管（`:9999`） | 3 | **3/3 PASS** | `r-a6741b1-thirdparty3.json` |
| `sing-box.exe` 缺失 | 5 | **5/5 PASS** | `r-a6741b1-missingcore5.json` |
| 故意使 core 启动失败 | 5 | **5/5 PASS** | `r-a6741b1-startfail5.json` |
| 快速启停循环（句柄/线程） | — | **12/12 PASS** | 句柄 314→315，线程 10→10，lateCores 0 |
| 重解压 ZIP 启停 | 6 | **≥6 PASS** | 上述各批次均在解压副本上运行 |
| 托盘鼠标真实退出 | 20 | **NOT RUN** | 见 §4.2 |
| Windows 注销/重启 | 视环境 | **NOT RUN** | 未在用户日常系统强制注销 |

无 crash / AV / UAF：全部批次退出码 0，无异常堆栈，无残留 GUI 或 core 进程，
端口 7899 每次释放，代理前后值逐次核对。**没有任何一次依赖测试工具 taskkill 通过**；
`pass` 与否在强制清理发生前就已判定，强制清理会把该次记为 FAIL（本轮未触发）。

### 4.2 未执行（如实标注）

| 测试项 | 目标 | 状态 | 原因 |
|---|---:|---|---|
| 一次性更新完成清理（50 次） | 50 | **NOT RUN** | 需要先构造 `profiles\*.bpf` 与可被 GUI 接受的订阅入口；`InputQuery` 订阅对话框无法自动化。**没有把它折算为通过。** |
| 下载中退出（20 次） | 20 | **NOT RUN** | 同上 |
| 回调排队时退出（20 次） | 20 | **NOT RUN** | 同上 |
| 重复更新 / 同文件写入（20 次） | 20 | **NOT RUN** | 同上 |
| 托盘鼠标真实退出（20 次） | 20 | **NOT RUN / MANUAL PENDING** | `Shell_NotifyIconGetRect` 在本会话对全部窗口/ID 组合均失败（`EnumWindows` + `HWND_MESSAGE` 全枚举 + ID 0–10 逐一探测），无法定位图标。按施工令**没有**用 `WM_CLOSE` 冒充。 |

已就绪的支撑件：`tools/mock-subscription-server.ps1`（localhost 订阅 mock，支持
`/sub`、`/slow`、`/403`、`/500`、`/bad`、`/abort`，实测可用），以及
`tools/targeted-scenarios.ps1`。

### 4.3 手工验收模板（托盘 20 次）

1. 解压 ZIP 到可写目录，双击 `JieJieBox.exe`，确认托盘出现图标。
2. 右键托盘图标 → 点击「退出」。
3. 记录：任务管理器中 `JieJieBox.exe` 与 `sing-box.exe` 是否都消失；
   `netstat -ano | findstr :7899` 是否无监听；
   `ProxyEnable`/`ProxyServer` 是否回到启动前的值。
4. 重复 20 次，记录成功次数。

未执行即维持 `NOT RUN`，不得折算为 `WM_CLOSE` 的通过数。

---

## 5. Actions

```text
workflow:  static validation (.github/workflows/static-validation.yml)
runner:    GitHub-hosted windows-latest
Delphi actually compiled in Actions: NO
安全隔离 Delphi runner: 不存在
ACTION_REAL_DELPHI_BUILD = BLOCKED: safe_delphi_action_runner_not_available
Artifact 下载复核: ARTIFACT_DOWNLOAD_NOT_VERIFIED
  （GitHub 对 artifact zip 即使公开仓库也要求认证，匿名返回 401；本机无 gh CLI、
   无 token。匿名 401 不被当作"artifact 不存在"。）
```

静态 workflow 真实 capable of 运行并在 `testing` 上 push 触发；它不编译客户端，
其头部与上传的 `result-scope.txt` 均写明 `delphi_build = NO`。
**没有把静态绿当成 Delphi CI 编译成功。**

---

## 6. 分支收口（G6）

现场核查（全部现场重查，未沿用旧报告）：

```text
origin/main     0ebf3793b8c337c113cb5c6847f0e726b35e53db
origin/testing  b5810f4（报告时）
default_branch  main
git ls-remote --heads origin  -> 2 条（main, testing）
main 是 testing 祖先           -> True
rev-list --count testing..main -> 0        （main 无独有提交）
rev-list --count main..testing -> 20
开放 PR                        -> 0
branch protection              -> 未确认（匿名读 protection 返回 401）
upstream remote                -> 已配置且 fetch 成功（upstream/main）
工作树                          -> clean
```

**`main` 未删除，`BRANCH_CLEANUP = BLOCKED`。**

阻塞原因是权限与可验证性，不是代码：

1. 本机**没有 `gh` CLI**（`Get-Command gh` 未找到），也没有可用的 GitHub token，
   因此无法调用 `PATCH /repos/...` 去修改 `default_branch`。
2. 施工令要求"先确认 `default_branch` 已切换并取得证据，再删除 `main`"。
   在无凭据情况下我既不能切换、也不能重新读取 `default_branch` 作为证据。
3. 删除 `main` 是不可逆的仓库管理操作；在没有前置证据时执行会违反该令的门禁。

需要管理员凭据时请执行：

```text
GitHub → Settings → General → Default branch: main → testing
然后 API 复查 .default_branch == "testing"
然后 git push origin --delete main
然后 git fetch origin --prune; git ls-remote --heads origin   # 应只剩 testing
```

`upstream/main` 全程保留，未触碰。没有创建任何第二条长期远程分支，没有 force push、
reset 或 history rewrite。

---

## 7. 未完成项 / 技术债务

| 级别 | 项 | 触发条件 | 影响 | 已验证范围 | 阻塞因素 | 下步行动 |
|---|---|---|---|---|---|---|
| P1 | 订阅状态机压力矩阵未执行 | 需可被 GUI 接受的订阅入口 | 一次性 worker 的压力面未被计数验证 | 所有权与单调度线程已由代码修复、编译通过 | 无 `profiles\*.bpf` fixture；`InputQuery` 对话框不可自动化 | 造 BPF fixture 或让 mock 走订阅添加入口 |
| P1 | 托盘真实点击 20 次 | 需人工桌面操作 | 真实用户路径未计数验证 | 同一 `FormCloseQuery`/`Shutdown` 路径已 20/20 | `Shell_NotifyIconGetRect` 在本会话不可用 | 按 §4.3 模板人工执行 |
| P1 | Windows 注销/关机 | 需隔离 VM | `WM_QUERYENDSESSION` 路径未验证 | — | 不得在用户日常系统强制注销 | 在测试 VM 中执行 |
| P2 | Actions artifact 下载复核 | 需 `actions:read` token | 云端产物未复核 | 静态 workflow run 成功 | 无 token、无 gh CLI | 提供 token 或人工登录下载 |
| P2 | 默认分支切换与删除 `main` | 需 admin 凭据 | fork 仍有 2 条分支 | 全部安全前提已核实 | 无凭据 | §6 的四步 |
| — | 公开二次分发授权 | 上游未明确许可 | 不得公开分发 | — | 法律层面 | 独立登记，与本轮技术验收无关 |

---

## 8. 本轮 commit 一览

```text
a6741b1 fix(profiles): give one-shot update workers explicit ownership, and do not
        let them run a second scheduler
b5810f4 test(p0): add targeted scenario harness and record the acceptance results
```

（另含此前 `757e6b4` 的 P0 优雅退出修复与 `84e3bb6b` 的报告。）
