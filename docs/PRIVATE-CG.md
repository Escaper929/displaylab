# PRIVATE-CG.md —— 用私有符号真正关掉一块显示器

## 为什么需要私有 API

公开的 CoreGraphics 提供的是**配置**显示器（分辨率、镜像、排列），**没有"关掉某一块"的接口**。
`CGConfigureDisplayEnabled` 这类朴素名字并不存在于公开头文件里。这也是 BetterDisplay 在
Intel 机型上做不到"彻底断开内建屏"的原因（它的断开功能依赖 Apple Silicon 才有的能力）。

真正干活的符号在 **SkyLight**（原 CoreGraphicsServices）：

```c
CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config,
                                   CGDirectDisplayID display,
                                   bool enabled);
```

`CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration` 是**公开**接口，
私有符号只是被塞进这个标准事务里调用。

## 调用约定

```swift
typealias CGSConfigureDisplayEnabledFn =
    @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
let symbol = dlsym(handle, "CGSConfigureDisplayEnabled")
let fn = unsafeBitCast(symbol, to: CGSConfigureDisplayEnabledFn.self)

var config: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&config)
fn(config, builtinDisplayID, false)          // false = 关掉
CGCompleteDisplayConfiguration(config, .forSession)   // 只对本次登录会话生效
```

实现见 `Sources/DisplayLab/Displays.swift`（`loadConfigureDisplayEnabled` / `applyDisplayEnabled`）。

## 实测行为（macOS 26.6.2, MacBookPro16,1）

| 调用 | 返回值 | 观察到 |
|---|---|---|
| `(69734662, false)` | `CGError 0` 成功 | 该屏被移出镜像集合（`在镜像集合` 由 是 → 否） |
| `(69734662, true)` | `CGError 0` 成功 | 该屏变为**活跃出画**，`NSScreen` 名字从空白解析为 `Built-in Retina Display` |

**符号仍存在**，用 `dlsym` 可解析。但要注意：

- 它只是告诉 macOS "别用这块屏"，**不会物理断电**面板。
- 系统在唤醒 / 解锁等时机可能自行恢复，需要重新 apply（MacHead 靠事件监听 + 常驻解决）。
- 符号出现在 macOS 10.6+，但**将来可能被移除**——所以必须 `dlopen`/`dlsym` 动态解析并优雅降级，
  不要编译期链接。

## 坑

1. **别用 `CGDisplayIsActive` 判断"是否被启用"**。实测它对内建屏恒为 `false`，
   且 `CGSConfigureDisplayEnabled(id, true)` 也不会让它翻转。要判断状态就看
   `CGDisplayIsInMirrorSet` / `CGDisplayMirrorsDisplay` 的变化，或者干脆看功耗。
2. **必须留安全阀**：关闭前确认除了目标屏之外还有别的屏在出画，否则等于把自己弄黑。
   注意安全阀不能用"在线屏总数"来判——目标屏本身可能已经是"在线但不出画"，计数会只剩 1。
3. **优先 `.forSession`**。`.permanently` 会写进系统配置，改坏了重启也回不来。
4. 别在同一个事务里同时改分辨率和启用状态；一次事务做一件事，行为更容易预测。

## 同类实现（可交叉验证）

- [ClamOpen](https://github.com/Attiv/clamOpen) —— 菜单栏小工具，外接屏时关内建屏，附独立
  "恢复"App 防黑屏，同样用 `CGSConfigureDisplayEnabled`
- [mac-display-control](https://github.com/hoainam12k/mac-display-control) —— CLI，明确写了
  "API 以 dlsym 动态加载"、"不能物理断电"、"macOS 可能在解锁/唤醒后恢复"
- MacHead.app（闭源）—— 本机已装，同款做法，逆向笔记见 [`MACHEAD.md`](MACHEAD.md)
