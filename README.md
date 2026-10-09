# JieJieBox for Windows

一个**极薄的 Windows 托盘外壳**，用来承载自定义内核
[`Piggy-Cat-bit-shadow/sing-box`](https://github.com/Piggy-Cat-bit-shadow/sing-box)。

它只负责生命周期、Windows 集成、订阅拉取、selector 交互和少量状态展示。
**TUN、mixed、DNS、route、sniff、outbounds、rule_set 全部由 sing-box 配置决定，GUI 不改写配置。**

```
JieJieBox GUI  →  生命周期 / Windows 集成 / 订阅 / selector / 状态
sing-box 配置  →  TUN / mixed / DNS / route / 所有代理行为
```

---

## 上游来源

Forked / based on [hdrover/sing-box-drover](https://github.com/hdrover/sing-box-drover).

> **授权提醒**：upstream 仓库目前**没有**明确的 `LICENSE` 文件或授权声明。
> 本项目保留原作者署名与来源链接，本地技术施工可以继续，
> 但**公开二次分发前必须先确认授权/许可证问题**。本仓库不擅自添加许可证结论。

---

## 特性

- **自带自定义内核**：发布包内直接包含来自
  [`Piggy-Cat-bit-shadow/sing-box`](https://github.com/Piggy-Cat-bit-shadow/sing-box)
  最新 Release 的 Windows x64 `sing-box.exe`，构建时 SHA256 校验，用户无需自己下载内核。
- **原生 JSON 配置优先**：配置文件里的内容原样交给内核，不做任何运行时裁剪或注入。
- **不修改 TUN / DNS / route**：配置里有 `tun` 就跑 TUN，有 `mixed` 就跑 mixed，两者都有就都交给内核。
- **自动 Windows 系统代理**：发现可用的 `mixed`/`http` inbound 时自动设置系统代理。
- **TUN 按配置自动提权**：配置含 `tun` inbound 时自动请求 UAC 并以管理员身份重启；
  拒绝 UAC 会明确报错退出，**不会偷偷降级成无 TUN 模式**。
- **BPF 远程订阅**：复用 sing-box 官方客户端的 `.bpf` profile 格式。
- **订阅更新**：自动周期更新 + 手动「立即更新」，两者共用同一个工作线程，永不并发。
- **Subscription-Userinfo**：顺带读取订阅响应头，托盘显示「已用 / 到期」。
- **selector**：配置自带 `experimental.clash_api` 时，托盘可切换 outbound selector。
- **简体中文托盘 UI**。

---

## 明确限制

- 订阅 URL **第一版只接受完整的 sing-box JSON 配置**。
- **不做** Clash YAML 转换、`vmess://` / `vless://` / `ss://` URI 解析、Base64 节点列表解析。
- **不做**运行时内核自动升级；内核在打包时锁定。
- 手动「立即更新」只对**当前生效的订阅**可用（切换订阅即完成刷新）。
- 「添加订阅」的下载与校验由后台更新线程完成，失败会以托盘气泡提示。

---

## 运行要求

- Windows 10 / 11 x64。
- 无需安装，解压即用。
- **仅当配置中包含 `tun` inbound 时需要管理员权限**（程序会自动请求）。

---

## 安装与使用

1. 解压发布包到任意目录，得到：

   ```
   JieJieBox.exe          客户端
   sing-box.exe           自定义内核（已内置）
   JieJieBox.ini          程序配置
   config.json            示例 sing-box 配置
   profiles\              订阅目录（为空）
   ```

2. 把你的 sing-box 配置保存为 `config.json`（或改 `JieJieBox.ini` 里的 `sb-config-file`）。
3. 双击 `JieJieBox.exe`。托盘出现图标即表示内核已启动。
4. **退出程序即可关闭内核**，没有额外的启动/停止按钮。

---

## 托盘菜单

```
● 运行中

订阅 >
    Airport A                  ✓
    Airport B
    ───────────────
    立即更新
    自动更新                   ✓
    上次更新：17:42
    ───────────────
    已用：58.2 GB / 100 GB
    到期：2026-11-20
    ───────────────
    添加订阅...
    打开订阅目录

[ selector 菜单，仅在配置自带 clash_api 时出现 ]

────────────────
更多 >
    内核：1.13.x-jiejie-v0.1.5
    重启内核
    开机启动                   ✓
    GitHub

退出
```

- 状态项不可点击，直接映射内核状态：`运行中` / `启动中...` / `已停止` / `启动失败`。
- **没有 TUN 开关，也没有系统代理开关。** 两者都由配置决定。
- 左键单击托盘图标只弹菜单，**不会偷偷改变任何网络模式**。
- 「内核」显示的是 `sing-box.exe version` 的真实输出，GUI 不维护第二份版本号。

---

## 配置文件

`JieJieBox.ini`（旧的 `sing-box-drover.ini` 仍会被读取，不会被改写）：

```ini
[JieJieBox]
sb-dir =
sb-config-file = config.json
; 以下两项已废弃，仅为兼容旧配置保留，程序会忽略它们：
;   tun inbound   -> 自动提权
;   mixed inbound -> 自动设置系统代理
tun-start-mode = off
; selector 菜单布局："auto"、"flat" 或 "nested"
selector-menu-layout = auto
selector-persist = 1
; 可选日志文件（绝对路径，或相对于程序目录的文件名）
log-file = JieJieBox.log
```

### 内核路径

优先使用**程序同目录**的 `sing-box.exe`。`sb-dir` 仅用于兼容旧安装，
发布包不要求用户配置它，UI 也不暴露「选择内核」。

---

## 订阅（BPF profile）

`profiles\` 目录下的每个 `.bpf` 文件就是一个订阅：

```
profiles\
├── Airport-A.bpf
├── Airport-B.bpf
└── MyConfig.bpf
```

- 没有数据库，`.bpf` 本身就是订阅对象（`name` / `remotePath` / `autoUpdate` / `interval` / `lastUpdated`）。
- 当前生效的订阅路径保存在 `JieJieBox.state.json` 的 `activeProfilePath`。
  该文件丢失或被删时，会安全回退到 `sb-config-file` 指向的普通配置。
- **只有当前生效的订阅更新成功时才会重启内核**；其他订阅更新只写文件，不碰运行中的内核。
- 当前生效的订阅不允许删除，需先切换到其他订阅。

### 添加订阅

菜单「订阅 → 添加订阅...」，输入**名称**和 **URL**。
程序会 HTTP GET 该 URL，要求返回**完整的 sing-box JSON 配置**，
校验通过后写入 `profiles\<名称>.bpf` 并设为当前订阅。

---

## 系统代理行为

| 配置情况 | 行为 |
| --- | --- |
| 有可用 `mixed` / `http` inbound | 启动时自动设置 Windows 系统代理；退出时恢复 |
| 没有 | 不设置、不报错、继续运行 |
| 退出程序 | **只有本次运行确实设置过系统代理时才恢复**，绝不无条件改动系统设置 |

---

## 从源码构建

需要 **RAD Studio 10.4 (Delphi) 或更高版本**，目标平台 `Win64`。

```powershell
# 1) 构建 GUI（Release / Win64）
#    用 IDE 打开 sing_box_drover.dproj 直接 Build，
#    或按 scripts\package-release.ps1 里的方式调用 MSBuild。

# 2) 获取并校验自定义内核
pwsh -File scripts\fetch-core.ps1

# 3) 一键打包（构建 + 取内核 + 组装 zip）
pwsh -File scripts\package-release.ps1
```

- `scripts\fetch-core.ps1`：解析 `Piggy-Cat-bit-shadow/sing-box` 的 latest release，
  **同一次构建只解析一次**，下载 `jiejie-sing-box-windows-amd64-*.zip`，
  与同一 Release 的 `SHA256SUMS` 比对，校验失败立即终止，解压得到 `sing-box.exe`。
- `scripts\package-release.ps1`：构建 GUI、调用上面的脚本取内核、组装 `dist\` 并生成 zip。
- `tools\make_app_res.py`：生成 `app.res`（托盘图标、VERSIONINFO、应用清单）。
  仅在更换图标或版本号后需要重跑。

### 关于 CI

upstream 没有可用的 Delphi CI，GitHub 官方 runner 也**不自带** RAD Studio
（Delphi 没有合法的免费 CI 授权）。因此本项目**不迁移技术栈**，
只保证**本地可复现的构建/打包脚本**。

---

## 已知限制

- 需要自行准备 Delphi 环境才能从源码构建（无预编译 GUI 的 CI 产物）。
- 「添加订阅」下载期间主线程会等待一次 HTTP 往返（最长约 45 秒超时）。
- 手动「立即更新」仅作用于当前生效的订阅。
- `.bpf` 是非公开的二进制容器格式，格式定义只存在于 sing-box 的 `libbox` 源码中。
