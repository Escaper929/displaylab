# MACHEAD.md —— MacHead.app 逆向笔记

对 `/Applications/MacHead.app` 的静态分析（没跑它的二进制，只读结构与字符串）。
它和我们解决的是同一个问题，用的是同一把钥匙，所以值得记下来。

## 身份

| 项 | 值 |
|---|---|
| 路径 | `/Applications/MacHead.app` |
| bundle id | `com.waffle.MacHead` |
| 版本 | 0.1.18（build 22），`LSMinimumSystemVersion 13.0` |
| 类型 | SwiftUI 菜单栏 App（`LSUIElement = true`，无 Dock 图标），universal（x86_64 + arm64） |
| 签名 | **adhoc**（`flags=0x2(adhoc)`，无 TeamIdentifier、无公证） |
| 来源 | headlessmac.com —— 定位是"把 MacBook 变成无头服务器"的工具 |
| 依赖 | SwiftUI / Cocoa / IOKit / CoreGraphics / CoreAudio / CFNetwork / Combine / ServiceManagement |

`Contents/` 里除主程序外还有：`Resources/nezha-agent`、`Resources/serverstatus-client`、
`Resources/Login.html`、`Resources/Dashboard.html`。

## 两条业务线

### 1. Headless Mode（核心，也是我们关心的部分）

- 存了一个 `BuiltInDisplayID`（本机 = `69734662`）用来定位内建屏。
- `dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")` +
  `dlsym("CGSConfigureDisplayEnabled")`，放进 `CGBeginDisplayConfiguration` /
  `CGCompleteDisplayConfiguration` 事务里关屏——公开 CG 没有这个能力。同款做法与坑见
  [`PRIVATE-CG.md`](PRIVATE-CG.md)。
- 同时持有 IOPM 断言 `PreventUserIdleSystemSleep`（其 CLI 帮助原文："Enable Headless Mode
  (turns off built-in display, locks sleep)"）。**对散热是反作用**：屏关了但机器永不空闲休眠。
- 附加项（字符串可见）：`DisableKeyboardAndTrackpadInHeadlessMode`、
  `MuteMicrophoneInHeadlessMode`。
- 自动响应外接屏插拔：`AutoExitHeadlessOnDisconnect`、`AutoRestoreHeadlessOnConnect`、
  `AutoEnableHeadlessOnLaunch`。
- 状态机三态：`headless` / `normal` / `offline`；自带 CLI
  （`-e/--enable`、`-d/--disable`、`-s/--status`、`--test`，含 4 个自测用例）。
- 本地 HTTP API：`/api/toggle-headless`、`/api/toggle-keyboard-headless`、
  `/api/toggle-restore-on-connect`，配 `WebServerPassword`。

### 2. 监控上报

- 捆绑 `nezha-agent`（哪吒监控）与 `serverstatus-client`：自己写配置文件、拉起进程、
  崩溃自动重启（字符串里全是 `NezhaAgentService:` / `ServerStatusService:` 的日志）。
- `UptimeKumaService`：向 Uptime Kuma 推心跳。
- `SMCManager`：直连 `AppleSMC` 读温度（`batteryTemperature`、`currentTemperature`），
  配合 `overheatAlertEnabled` 做过热告警。
- `NotificationService`：通知中心 / Bark（`https://api.day.app/push`）/ Telegram Bot
  （`https://api.telegram.org/bot`）。
- 遥测：`https://headlessmac.com/api/telemetry`，带匿名设备 ID
  （`MacHead_Anonymous_Device_ID`）。
- **OTA 自更新**：拉 `https://headlessmac.com/appcast.json` → 下载 DMG →
  挂载到 `/tmp/MacHeadMount` → 替换自己的 app bundle → **递归剥掉 quarantine**。

## 本机实际状态（2026-09-23 快照）

```
defaults read com.waffle.MacHead
  HeadlessModeEnabled = 1          BuiltInDisplayID = 69734662
  AutoEnableHeadlessOnLaunch = 0   EnableWebServer = 0
  WebServerPassword = <本机已设置，值不记录>
  overheatAlertEnabled = 1
```

- 没有 LaunchAgent、没有 `/Library/PrivilegedHelperTools` 条目、没有登录项
  → **只有 App 在运行时无头模式才生效**；当时进程并未运行。
- `pmset -g assertions` 中也没有它的休眠断言。

## 风险提示

1. **adhoc 签名 + 自替换 bundle + 剥 quarantine**：等于一条绕开 Gatekeeper 的自动更新链，
   供应链上任何一环被替换都不会有人拦。
2. 敏感值明文存在 UserDefaults：nezha secret、ServerStatus 密码、WebServerPassword、
   Bark Key。
3. 会以你的名义常驻并写配置运行两个第三方 Go agent。
4. 无头模式**锁休眠**——如果你的目标是降温，这点必须和它说清楚（见 `FINDINGS.md` 第 11 条）。
