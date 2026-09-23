# FINDINGS.md —— 已验证的事实清单

每条都标注了证据来源与复现命令。**"估算"和"实测"必须分清**，这个项目里已经因此返工过一次
（见第 7 条），不要把按模式算出来的数字当测量结果用。

测试机：MacBookPro16,1（2019 16"）/ i7-9750H / 16 GB / macOS 26.6.2 (25G83)。
面板已整体拆除，仅内屏排线接在主板；常年外接一台 U2790B（4K）。

---

## 1. 屏幕挂在哪块 GPU 下

```
AppleBacklightDisplay（内屏，面板已不在）  =>  独显
    AppleBacklightDisplay > display0 > ATY,Boa > AMDRadeonX6000_AmdRadeonControllerNavi14 > GFX0 > IOPP > EGP1 > IOPP …
AppleDisplay（外接 U2790B）                =>  独显
    AppleDisplay > display0 > ATY,Boa > AMDRadeonX6000_AmdRadeonControllerNavi14 > GFX0 > IOPP > EGP1 > IOPP …
```

本机 ACPI 命名：**`GFX0`（父节点是 `PEG0`，PCIe 显卡根端口）= 独显**，`IGPU@2` = 集显。
集显那侧 `AppleIntelFramebuffer@0` 下**没有任何 `IODisplayConnect`** —— 它没接任何屏。

复现：`displaylab who`、`scripts/gpu-owner.sh`

## 2. gMux 定格在独显

```
ActiveGPU：GFX0        检测到外接屏：是
gMux 版本：5.0.0       上电以来 mux 切换次数：0
切换策略 policy：2（自动切换）
```

`SwitchCount = 0` 说明开机至今 mux 从未切换过。复现：`displaylab who`、`ioreg -rc AppleMuxControl`

## 3. "外接屏 = 独显常开"是硬件布线，不是软件策略

Apple 官方文档《在 MacBook Pro 上设置图形处理性能》原文：*"如果将外接显示器连接到 Mac，
那么在断开显示器的连接之前，电脑会一直使用高性能图形处理器。"* 社区亦有长期讨论
（MacRumors "2019 16" is HOT & NOISY with an external monitor"，64 页）指出对外 DisplayPort
lane 只接到独显，独显仅因接线存在就要多吃 5–10 W。

因此 `gpuswitch` 无法把外接屏挪到集显——切过去只会得到黑屏或设置被忽略。
想实测请用 `scripts/force-igpu-test.sh`（自带自动回滚；**跑之前必须先开 SSH 远程登录**，
因为 `gpuswitch` 会持久化，重启不还原）。

## 4. gpuswitch 的取值

`pmset -g` → `0 = 只集显 / 1 = 只独显 / 2 = 自动`。本机为 `2`。
官方 GUI 对应项：系统设置 → 电池 → 选项 → "自动切换图形卡模式"。

## 5. 幽灵内屏：面板不在，链路还在

面板缺失时 macOS 仍会登记一台在线显示器，用的是**合成 EDID**（名字 `Color LCD`、
厂商 `0610` = Apple、产品 `0xa044`），并给它分配时序、和 4K 外接屏建立硬件镜像关系。

复现：`ioreg -rc AppleBacklightDisplay`、`system_profiler SPDisplaysDataType`

## 6. ⚠ `CGDisplayIsActive` 不能用来判断"是否被启用"

实测：内建屏恒为 `在用=否`，而且**调用 `CGSConfigureDisplayEnabled(id, true)` 之后依然是 `否`**——
这个标志与启用状态无关（至少对这块屏恒定）。唯一观察到它翻转的时机是：把该屏移出镜像集合
并重新启用后，`NSScreen` 才会把它解析成 `Built-in Retina Display` 且 `在用=是`。

**踩坑记录**：曾据此推断"内屏当前在出画"，进而高估了它的代价。教训见第 7 条。

## 7. ⚠ 静态模式相加 ≠ 实测负载（本项目最重要的一条教训）

`displaylab list` 的 `Mpix/s` 是**按模式推算的估算**（`像素宽 × 像素高 × 刷新率`），
只有当 `出画=是` 时才成立。曾把两块屏的模式相加得出"995 Mpix/s、一半浪费在死链路上"，
这个结论**已被实测推翻**：该屏本来就没在出画。

受控 A/B（`displaylab gpu --avg 12`，依次为 基线 → 关闭内建屏 → 恢复）：

| 阶段 | 独显平均功耗 | 平均温度 | 平均利用率 |
|---|---|---|---|
| 基线 | 9.8 W（8–13） | 68.2 °C | 12.1 % |
| 关闭内建屏后 | 10.4 W（7–14） | 69.4 °C | 11.7 % |
| 再次关闭（晚些时候） | 14.0 W（10–22） | 74.6 °C | 18.8 % |

差异完全落在**机器整体活动的噪声**里（第三次偏高是采样时段本身负载更高）。
结论：**开关这块死链路屏省不到瓦数**，因为它本来就几乎不耗电。

## 8. 真实的代价：独显常开

```
19:46:19  独显功耗 8 W  温度 68°C  利用率 15%  活动 13%  核心 77 MHz / 显存 304 MHz
采样 5 秒   平均功耗 12.2 W（最低 10 / 最高 13）  平均温度 68.2°C  平均利用率 8.8%
```

空载 8–15 W、68–75 °C。**这是发烫的账**，其它优化都是小钱。

## 9. GPU 遥测的取数方式（不需要 root）

`IORegistry` 中 AMD 加速器节点的 `PerformanceStatistics` 字典直接带
`Total Power(W)` / `Temperature(C)` / `Device Utilization %` / `GPU Activity(%)` /
`Core Clock(MHz)` / `Memory Clock(MHz)` / `Fan Speed(RPM)`。

坑：同一份字典里混着溢出成 `UInt64` 的计数（如 `stdTextureCreationBytes` = 1.8e19），
**整表转 `Int` 会炸**；只能按白名单取键，并统一走 `NSNumber.intValue`。

复现：`displaylab gpu`（实现见 `Sources/DisplayLab/GPUTelemetry.swift`）

## 10. 与 keyglow 的边界：拔显示排线不影响键盘背光

keyglow 控制的键盘背光是 **Top Case 背光总线**上的 HID 设备（T2 虚拟 USB 暴露的
`Touch Bar Backlight`，VID `0x05AC` / PID `33026`，UsagePage `0xFF00` / Usage `15`），
与 eDP 显示排线不是一路。拔掉显示排线不会影响它，也不会影响键盘/触控板
（两者都在 Top Case 上）；相机与环境光传感器则本来就随面板一起没了。

## 11. 还剩哪些路

| 方案 | 拿到什么 | 代价 |
|---|---|---|
| 拔掉 eDP 排线 | 幽灵屏彻底消失，不依赖任何常驻进程 | 要拆机；先断电并断开电池（背光供电轨可能带电） |
| MacHead 的 Headless 模式 | 用私有 API 关掉内建屏 + 唤醒后自动恢复 | 会同时持 `PreventUserIdleSystemSleep`（**锁休眠，与散热目标相反**）；见 `docs/MACHEAD.md` |
| 自建 LaunchAgent | 只在唤醒后重新 `displaylab off`，不碰休眠 | 多一个常驻项 |
| DisplayLink 适配器 | **唯一能让外接屏不吃独显的现实方案**（画面走 USB 显卡芯片） | 要买硬件，有压缩与延迟 |
| 低功耗模式 | CPU 端单点降温最明显 | `sudo pmset -a lowpowermode 1`，随时可还原 |
| 无头 + 屏幕共享 | 独显可真正断电，最凉 | 需要另一台机器看画面 |
