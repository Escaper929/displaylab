// DisplayTools.swift —— 量化并收缩「幽灵内屏」的扫描输出负载
//
// 背景：这台机器面板整体拆掉了，但内屏排线仍接在主板上，于是 macOS 把这个死链路
//       当成一台在线显示器（合成 EDID "Color LCD"），分配了独立时序 3072×1920@60，
//       还要把 4K 外接屏的画面缩放到这个时序再扫一遍 —— 画面没有任何人看得到。
//
// 本工具做三件事：
//   list              只读：列出所有在线显示器、当前模式、镜像关系、各屏像素负载合计
//   shrink-internal   把内屏解除镜像并切到「桌面可用模式里最省的一个」
//   restore-internal  把内屏重新镜像回主屏（恢复原状）
//
// shrink/restore 都用 CGConfigureForSession：改动只在本次登录会话内有效，
// 注销或重启自动还原 —— 万一效果不对，退出登录即可，不会把你锁在黑屏里。
//
// 编译：swiftc -O -o displaytools DisplayTools.swift
// 用法：./displaytools list

import Foundation
import AppKit
import CoreGraphics

// ── 辅助 ────────────────────────────────────────────────────────────────────

func pixelLoad(_ m: CGDisplayMode) -> Double {
    let hz = m.refreshRate > 0 ? m.refreshRate : 60
    return Double(m.pixelWidth) * Double(m.pixelHeight) * hz
}

func modeDesc(_ m: CGDisplayMode) -> String {
    var s = String(format: "%d×%d @%.0fHz", m.width, m.height, m.refreshRate)
    if m.pixelWidth != m.width || m.pixelHeight != m.height {
        s += String(format: "（像素 %d×%d）", m.pixelWidth, m.pixelHeight)
    }
    return s
}

func loadDesc(_ m: CGDisplayMode) -> String {
    String(format: "%.0f Mpix/s", pixelLoad(m) / 1_000_000)
}

func screenName(for id: CGDirectDisplayID) -> String {
    for s in NSScreen.screens {
        if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           n.uint32Value == id {
            return s.localizedName
        }
    }
    return "（无窗口服务信息）"
}

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func modes(of id: CGDirectDisplayID) -> [CGDisplayMode] {
    guard let arr = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] else { return [] }
    return arr
}

func cheapestDesktopMode(of id: CGDirectDisplayID) -> CGDisplayMode? {
    modes(of: id)
        .filter { $0.isUsableForDesktopGUI() }
        .min { pixelLoad($0) < pixelLoad($1) }
}

func currentMode(of id: CGDirectDisplayID) -> CGDisplayMode? {
    CGDisplayCopyDisplayMode(id)
}

// ── 子命令 ──────────────────────────────────────────────────────────────────

func cmdList() {
    let builtin = CGMainDisplayID()
    _ = builtin
    print("在线显示器（\(onlineDisplays().count) 块）")
    print("────────────────────────────────────────────────────────────")
    var total: Double = 0
    for (i, id) in onlineDisplays().enumerated() {
        let isBuiltin = CGDisplayIsBuiltin(id) != 0
        let mirrorOf = CGDisplayMirrorsDisplay(id)
        let m = currentMode(of: id)
        let drawing = CGDisplayIsActive(id) != 0 && CGDisplayIsAsleep(id) == 0
        let load = drawing ? (m.map(pixelLoad) ?? 0) : 0
        total += load

        print("[\(i + 1)] \(screenName(for: id))")
        print("   display id   : \(id)")
        print("   内建 / 主屏   : \(isBuiltin ? "是" : "否") / \(CGDisplayIsMain(id) != 0 ? "是" : "否")")
        print("   是否在出画   : \(drawing ? "是" : "否 —— 只是登记在册，不产生扫描输出")")
        if mirrorOf != 0 {
            print("   镜像自       : display \(mirrorOf)（硬件镜像，时序由主屏决定）")
        } else {
            print("   镜像自       : 无（独立时序）")
        }
        if let m {
            print("   当前模式     : \(modeDesc(m))   \(drawing ? "负载 \(loadDesc(m))" : "（未出画，不计负载）")")
        }
        print("   可选模式     : \(modes(of: id).count) 个")

        if isBuiltin, let cheapest = cheapestDesktopMode(of: id) {
            print("   最省模式     : \(modeDesc(cheapest))   \(loadDesc(cheapest))")
            if let m, drawing {
                let save = (pixelLoad(m) - pixelLoad(cheapest)) / pixelLoad(m) * 100
                print(String(format: "   单这一块可省 : %.0f%% 的扫描输出", save))
            }
        }
        print()
    }
    print(String(format: "正在出画的显示器合计扫描负载：%.0f Mpix/s", total / 1_000_000))
    print("说明：这个数字是「按模式推算」的静态估算，只有在出画=是 的屏上才成立；")
    print("      想看真实的 GPU 功耗与温度，用 ./gpu-stat.sh。")
}

func apply(session: Bool, _ body: (CGDisplayConfigRef) -> Void) -> CGError {
    var cfg: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&cfg)
    guard begin == .success, let cfg else { return begin }
    body(cfg)
    return CGCompleteDisplayConfiguration(cfg, session ? .forSession : .permanently)
}

func cmdShrinkInternal() {
    guard let internalID = onlineDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
        print("没有找到内建显示屏 —— 排线可能已经拔掉，那就无需处理了。")
        return
    }
    guard let target = cheapestDesktopMode(of: internalID) else {
        print("内建显示屏没有可用的桌面模式，未做改动。")
        return
    }
    let before = currentMode(of: internalID)
    let mainID = CGMainDisplayID()

    let err = apply(session: true) { cfg in
        // 先解除镜像（硬件镜像会强制从屏跟随主屏时序），再切到最省模式
        CGConfigureDisplayMirrorOfDisplay(cfg, internalID, kCGNullDirectDisplay)
        CGConfigureDisplayWithDisplayMode(cfg, internalID, target, nil)
    }

    switch err {
    case .success:
        if let a = before, let b = currentMode(of: internalID) {
            print("内建显示屏已收缩：\(modeDesc(a))  →  \(modeDesc(b))")
            print(String(format: "扫描输出从 %.0f 降到 %.0f Mpix/s", pixelLoad(a) / 1_000_000, pixelLoad(b) / 1_000_000))
        }
        print("注意：它现在是一块「独立但无人可见」的桌面，鼠标可能滑到那边去；")
        print("      主屏 \(mainID) 不受影响。要还原：./displaytools restore-internal，或直接注销/重启。")
    default:
        print("配置未生效，CGError = \(err.rawValue)（系统可能拒绝了本次会话内的显示配置变更）")
        print("没有留下任何改动。")
    }
}

func cmdRestoreInternal() {
    guard let internalID = onlineDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
        print("没有找到内建显示屏。")
        return
    }
    let mainID = CGMainDisplayID()
    let err = apply(session: true) { cfg in
        CGConfigureDisplayMirrorOfDisplay(cfg, internalID, mainID)
    }
    if err == .success {
        print("内建显示屏已重新镜像到主屏 \(mainID)（恢复原状）。")
    } else {
        print("还原失败，CGError = \(err.rawValue)。注销或重启一定会恢复原状。")
    }
}

// ── 入口 ────────────────────────────────────────────────────────────────────

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "list" {
case "list":
    cmdList()
case "shrink-internal":
    cmdShrinkInternal()
case "restore-internal":
    cmdRestoreInternal()
case "-h", "--help", "help":
    print("""
    用法：displaytools <子命令>

      list              只读：列出在线显示器、模式、镜像关系与扫描负载（默认）
      shrink-internal   内屏解除镜像并切到最省模式（仅本次会话有效）
      restore-internal  内屏重新镜像回主屏
    """)
default:
    print("未知子命令：\(args[0])，试 ./displaytools help")
}
