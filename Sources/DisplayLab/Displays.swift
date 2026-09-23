import Foundation
import AppKit
import CoreGraphics
import Darwin

// MARK: - 显示器枚举与模式计算

func pixelLoad(_ mode: CGDisplayMode) -> Double {
    let hz = mode.refreshRate > 0 ? mode.refreshRate : 60
    return Double(mode.pixelWidth) * Double(mode.pixelHeight) * hz
}

func modeDesc(_ mode: CGDisplayMode) -> String {
    var text = String(format: "%d×%d @%.0fHz", mode.width, mode.height, mode.refreshRate)
    if mode.pixelWidth != mode.width || mode.pixelHeight != mode.height {
        text += String(format: "（像素 %d×%d）", mode.pixelWidth, mode.pixelHeight)
    }
    return text
}

func loadDesc(_ mode: CGDisplayMode) -> String {
    String(format: "%.0f Mpix/s", pixelLoad(mode) / 1_000_000)
}

func screenName(for id: CGDirectDisplayID) -> String {
    for screen in NSScreen.screens {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           number.uint32Value == id {
            return screen.localizedName
        }
    }
    return "（无窗口服务信息 —— 通常是内建屏）"
}

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func builtinDisplay() -> CGDirectDisplayID? {
    onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }
}

func modes(of id: CGDirectDisplayID) -> [CGDisplayMode] {
    (CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode]) ?? []
}

func currentMode(of id: CGDirectDisplayID) -> CGDisplayMode? {
    CGDisplayCopyDisplayMode(id)
}

func cheapestDesktopMode(of id: CGDirectDisplayID) -> CGDisplayMode? {
    modes(of: id)
        .filter { $0.isUsableForDesktopGUI() }
        .min { pixelLoad($0) < pixelLoad($1) }
}

/// 是否真的在出画。注意：这个标志对「在线但没在出画」的内建屏恒为 false，
/// 且不受 CGSConfigureDisplayEnabled 影响 —— 详见 docs/FINDINGS.md，
/// 不要拿它当"是否被启用"的判断依据。
func isDrawing(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayIsActive(id) != 0 && CGDisplayIsAsleep(id) == 0
}

func drawingDisplays(excluding excluded: CGDirectDisplayID? = nil) -> [CGDirectDisplayID] {
    onlineDisplays().filter { id in
        if let excluded, id == excluded { return false }
        return isDrawing(id)
    }
}

// MARK: - list

func cmdList() {
    let ids = onlineDisplays()
    print("在线显示器：\(ids.count) 块")
    print(String(repeating: "─", count: 60))

    var total: Double = 0
    for (index, id) in ids.enumerated() {
        let builtin = CGDisplayIsBuiltin(id) != 0
        let drawing = isDrawing(id)
        let mode = currentMode(of: id)
        if drawing, let mode { total += pixelLoad(mode) }

        print("[\(index + 1)] \(screenName(for: id))")
        print("   display id    : \(id)")
        print("   内建 / 主屏    : \(builtin ? "是" : "否") / \(CGDisplayIsMain(id) != 0 ? "是" : "否")")
        print("   在线 / 出画    : 是 / \(drawing ? "是" : "否（只是登记在册，不产生扫描输出）")")
        print("   休眠          : \(CGDisplayIsAsleep(id) != 0 ? "是" : "否")")
        let mirrorOf = CGDisplayMirrorsDisplay(id)
        print("   镜像自        : \(mirrorOf == 0 ? "无（独立时序）" : "display \(mirrorOf)")")
        print("   在镜像集合    : \(CGDisplayIsInMirrorSet(id) != 0 ? "是" : "否")")
        if let mode {
            if drawing {
                print("   当前模式      : \(modeDesc(mode))   负载 \(loadDesc(mode))")
            } else {
                print("   当前模式      : \(modeDesc(mode))   —— 未出画，这个模式只是残留值，别当负载")
            }
        }
        print("   可选模式数    : \(modes(of: id).count)")
        if builtin, let cheapest = cheapestDesktopMode(of: id) {
            print("   最省模式      : \(modeDesc(cheapest))   \(loadDesc(cheapest))")
        }
        print()
    }

    print(String(format: "正在出画的显示器合计扫描负载：%.0f Mpix/s", total / 1_000_000))
    print("说明：这是按模式推算的**静态估算**，只在「出画=是」的屏上才成立。")
    print("      要看真实代价请看 `displaylab gpu`（独显功耗/温度），别用估算当测量。")
}

// MARK: - 私有 API：真正关闭一块显示器

// CGSConfigureDisplayEnabled 是 SkyLight 的私有符号，公开的 CoreGraphics 没有这个能力
// （这也是 BetterDisplay 在 Intel 机型上做不到彻底断开内屏的原因）。
// 原型与调用约定见 docs/PRIVATE-CG.md。
typealias CGSConfigureDisplayEnabledFn =
    @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

@discardableResult
func loadConfigureDisplayEnabled() -> CGSConfigureDisplayEnabledFn? {
    guard let handle = dlopen(skyLightPath, RTLD_NOW) else {
        print("dlopen 失败：\(String(cString: dlerror()))")
        return nil
    }
    guard let symbol = dlsym(handle, "CGSConfigureDisplayEnabled") else {
        print("SkyLight 中找不到 CGSConfigureDisplayEnabled —— 本版 macOS 已移除该符号。")
        return nil
    }
    return unsafeBitCast(symbol, to: CGSConfigureDisplayEnabledFn.self)
}

func applyDisplayEnabled(_ id: CGDirectDisplayID, _ enabled: Bool,
                         fn: CGSConfigureDisplayEnabledFn) -> Bool {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else {
        print("CGBeginDisplayConfiguration 失败")
        return false
    }
    let callError = fn(config, id, enabled)
    // 只提交到本次登录会话：注销/重启自动复原，改坏了不会把机器留在黑屏状态。
    let commitError = CGCompleteDisplayConfiguration(config, .forSession)
    print("CGSConfigureDisplayEnabled(\(id), \(enabled)) → CGError \(callError.rawValue)"
          + "，提交 \(commitError.rawValue)（0 = 成功）")
    return callError == .success && commitError == .success
}

func cmdSetBuiltin(_ enabled: Bool) {
    guard let fn = loadConfigureDisplayEnabled() else { exit(1) }
    guard let builtin = builtinDisplay() else {
        print("没有内建屏节点（排线可能已拔掉）—— 无需处理。")
        return
    }

    if !enabled {
        // 安全阀：必须还存在另一块正在出画的屏，否则关掉内建屏后你将失去画面。
        // 不能用"在线屏总数"判断 —— 内建屏本身可能已经是不出画状态。
        let others = drawingDisplays(excluding: builtin)
        guard !others.isEmpty else {
            print("拒绝执行：除了内建屏之外没有第二块正在出画的屏，关掉它你将失去画面。")
            exit(2)
        }
    }

    if applyDisplayEnabled(builtin, enabled, fn: fn) {
        print(enabled ? "已恢复内建屏。" : "已关闭内建屏。恢复：displaylab on（或注销/重启）")
    } else {
        print("未生效 —— 系统拒绝了本次变更，显示状态未改变。")
        exit(3)
    }
}
