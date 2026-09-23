// headless-display.swift —— 关掉「幽灵内屏」的那条死链路（MacHead 同款私有 API）
//
// 背景：这台 MacBookPro16,1 面板已整体拆掉，只剩内屏排线插在主板上。macOS 因此把这条
//       空链路当成一台在线显示器（合成 EDID "Color LCD"），还把它和 4K 外接屏做硬件镜像，
//       于是有一半的扫描输出打在没人看得到的死链路上。
//
// 公开的 CoreGraphics 没有「关掉某块显示器」的接口，只能用 SkyLight 的私有符号：
//
//     CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);
//
// 该符号通过 dlsym 动态解析，塞进标准重配置事务里调用（与 MacHead / ClamOpen /
// mac-display-control 的做法一致）。注意：私有 API 只告诉 macOS「别用这块屏」，
// 并不能物理断电；系统在唤醒/解锁后可能自行恢复，必要时需要重新执行。
//
// 子命令：
//   status   只读：解析符号、列出显示器与启用状态（默认）
//   off      关闭内置屏（内置屏是唯一在用屏时拒绝执行）
//   on       恢复内置屏
//
// 编译：swiftc -O -o headless-display headless-display.swift

import Foundation
import AppKit
import CoreGraphics
import Darwin

let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

typealias CGSConfigureDisplayEnabledFn =
    @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

func loadConfigureFn() -> CGSConfigureDisplayEnabledFn? {
    guard let handle = dlopen(skyLightPath, RTLD_NOW) else {
        print("dlopen 失败：\(String(cString: dlerror()))")
        return nil
    }
    guard let sym = dlsym(handle, "CGSConfigureDisplayEnabled") else {
        print("SkyLight 里找不到 CGSConfigureDisplayEnabled —— 本版 macOS 已移除该符号。")
        return nil
    }
    print("✓ 符号已解析：CGSConfigureDisplayEnabled @ SkyLight.framework")
    return unsafeBitCast(sym, to: CGSConfigureDisplayEnabledFn.self)
}

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func screenName(for id: CGDirectDisplayID) -> String {
    for s in NSScreen.screens {
        if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           n.uint32Value == id {
            return s.localizedName
        }
    }
    return "（内建/无窗口服务信息）"
}

func dumpDisplays() -> (builtin: CGDirectDisplayID?, activeCount: Int) {
    let ids = onlineDisplays()
    var active = 0
    var builtin: CGDirectDisplayID?
    print("在线显示器：\(ids.count) 块")
    for id in ids {
        let isBuiltin = CGDisplayIsBuiltin(id) != 0
        let isActive = CGDisplayIsActive(id) != 0
        let isOnline = CGDisplayIsOnline(id) != 0
        let isAsleep = CGDisplayIsAsleep(id) != 0
        if isActive && !isAsleep { active += 1 }
        if isBuiltin { builtin = id }
        print("  · \(screenName(for: id))  id=\(id)  内建=\(isBuiltin ? "是" : "否")")
        print("      在线=\(isOnline ? "是" : "否")  在用=\(isActive ? "是" : "否")  "
              + "休眠=\(isAsleep ? "是" : "否")  "
              + "在镜像集合=\(CGDisplayIsInMirrorSet(id) != 0 ? "是" : "否")  "
              + "镜像自=\(CGDisplayMirrorsDisplay(id))")
    }
    print("正在出画（在用且未休眠）的显示器数量：\(active)")
    return (builtin, active)
}

func setEnabled(_ builtin: CGDirectDisplayID, _ enabled: Bool, fn: CGSConfigureDisplayEnabledFn) -> Bool {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else {
        print("CGBeginDisplayConfiguration 失败")
        return false
    }
    let err = fn(cfg, builtin, enabled)
    let commit = CGCompleteDisplayConfiguration(cfg, .forSession)
    print("CGSConfigureDisplayEnabled(\(builtin), \(enabled ? "true" : "false")) → CGError \(err.rawValue)"
          + "   提交结果 \(commit.rawValue)")
    return err == .success && commit == .success
}

switch CommandLine.arguments.dropFirst().first ?? "status" {
case "status":
    _ = loadConfigureFn()
    print()
    _ = dumpDisplays()
    print("\n提示：off/on 只作用于「内建」那块屏，改动限于本次登录会话，注销或重启即复原。")

case "off":
    guard let fn = loadConfigureFn() else { exit(1) }
    let (builtin, _) = dumpDisplays()
    guard let builtin else { print("没有内建屏，无需处理。"); exit(0) }
    // 安全阀：必须还存在「另一块正在出画」的屏，否则关掉内建屏后你将失去画面。
    // 注意不能拿"在用屏总数"来判断 —— 内建屏本身可能已经是"在线但未出画"的状态，
    // 那样计数会只剩 1，把这种情况误判成"最后一块屏"。
    let others = onlineDisplays().filter {
        $0 != builtin && CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0
    }
    guard !others.isEmpty else {
        print("拒绝执行：除了内建屏之外没有第二块正在出画的屏，关掉它你将失去画面。")
        exit(2)
    }
    if setEnabled(builtin, false, fn: fn) {
        print("已请求关闭内建屏。用 `./headless-display on` 或注销/重启恢复。")
    } else {
        print("未生效 —— 系统拒绝了本次变更，显示状态未改变。")
        exit(3)
    }

case "on":
    guard let fn = loadConfigureFn() else { exit(1) }
    guard let builtin = onlineDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
        print("找不到内建屏节点（排线可能已拔掉）。")
        exit(0)
    }
    _ = setEnabled(builtin, true, fn: fn)

default:
    print("""
    用法：headless-display <子命令>

      status   只读：解析私有符号并列出显示器状态（默认）
      off      关闭内建屏（唯一在用屏时拒绝执行）
      on       恢复内建屏
    """)
}
