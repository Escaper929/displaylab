import SwiftUI
import AppKit
import CoreGraphics
import Darwin

// DisplayLabMenu —— 菜单栏小工具
//
// 把 displaylab 最常用的两件事做成一键开关：
//   1. 关闭 / 恢复内建屏（CGSConfigureDisplayEnabled，会话级、可逆）
//   2. 自动值守：内建屏被系统恢复（唤醒/解锁）后自动重新关闭
//
// 与 CLI 的约定一致：
//   · 只作用于内建屏，用 kCGConfigureForSession 提交，注销/重启自动复原
//   · 安全阀：没有第二块正在出画的屏时，拒绝关闭内建屏（否则黑屏）
//   · 私有符号 dlopen/dlsym 动态解析，优雅降级

// MARK: - 私有 API

typealias CGSConfigureDisplayEnabledFn =
    @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

@discardableResult
func loadConfigureDisplayEnabled() -> CGSConfigureDisplayEnabledFn? {
    guard let handle = dlopen(skyLightPath, RTLD_NOW) else { return nil }
    guard let symbol = dlsym(handle, "CGSConfigureDisplayEnabled") else { return nil }
    return unsafeBitCast(symbol, to: CGSConfigureDisplayEnabledFn.self)
}

// MARK: - 显示器查询

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

func isDrawing(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayIsActive(id) != 0 && CGDisplayIsAsleep(id) == 0
}

func drawingDisplays(excluding excluded: CGDirectDisplayID? = nil) -> [CGDirectDisplayID] {
    onlineDisplays().filter { id in
        if let excluded, id == excluded { return false }
        return isDrawing(id)
    }
}

/// 内建屏是否处于「被关掉」的目标状态。不能靠 CGDisplayIsActive（对内建屏恒 false），
/// 而是看镜像集合 / 出画三者是否有任一翻回真。
func builtinNeedsDisable(_ builtin: CGDirectDisplayID) -> Bool {
    if CGDisplayIsInMirrorSet(builtin) != 0 { return true }
    if CGDisplayMirrorsDisplay(builtin) != 0 { return true }
    if isDrawing(builtin) { return true }
    return false
}

// MARK: - 核心操作

enum ActionResult {
    case success(String)
    case failure(String)
}

func setBuiltinEnabled(_ enabled: Bool) -> ActionResult {
    guard let fn = loadConfigureDisplayEnabled() else {
        return .failure("找不到 CGSConfigureDisplayEnabled（本版 macOS 可能已移除该符号）")
    }
    guard let builtin = builtinDisplay() else {
        return .failure("没有内建屏节点（排线可能已拔掉）")
    }
    if !enabled {
        let others = drawingDisplays(excluding: builtin)
        guard !others.isEmpty else {
            return .failure("除了内建屏没有第二块在出画的屏，关掉会黑屏，已拒绝")
        }
    }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else {
        return .failure("CGBeginDisplayConfiguration 失败")
    }
    let callError = fn(config, builtin, enabled)
    let commitError = CGCompleteDisplayConfiguration(config, .forSession)
    if callError == .success && commitError == .success {
        return .success(enabled ? "已恢复内建屏" : "已关闭内建屏")
    } else {
        return .failure("调用失败（CGError \(callError.rawValue)/\(commitError.rawValue)）")
    }
}

// MARK: - 值守引擎（一个轻量定时器，检测到内屏被恢复就重新关）

final class Watchdog: ObservableObject {
    @Published var isRunning = false
    @Published var lastLog = "未启动"
    private var timer: Timer?
    private var fn: CGSConfigureDisplayEnabledFn?

    func start() {
        guard !isRunning else { return }
        guard let loaded = loadConfigureDisplayEnabled() else {
            lastLog = "无法加载私有符号"
            return
        }
        fn = loaded
        isRunning = true
        lastLog = "值守已启动"
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()  // 立即执行一次
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        lastLog = "值守已停止"
    }

    private func tick() {
        guard let fn else { return }
        guard let builtin = builtinDisplay() else {
            lastLog = "无内建屏节点，跳过"
            return
        }
        let others = drawingDisplays(excluding: builtin)
        if builtinNeedsDisable(builtin) && !others.isEmpty {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let config {
                let e = fn(config, builtin, false)
                _ = CGCompleteDisplayConfiguration(config, .forSession)
                lastLog = "已自动重新关闭内建屏（\(Date().formatted(date: .omitted, time: .standard))）"
                _ = e
            }
        }
    }
}

// MARK: - 菜单栏 App

@main
struct DisplayLabMenuApp: App {
    @StateObject private var watchdog = Watchdog()
    @State private var builtinClosed: Bool
    @State private var statusMessage = ""

    init() {
        // 启动时同步内建屏的真实状态，避免图标与系统实际状态脱节。
        var closed = false
        if let builtin = builtinDisplay() {
            closed = !builtinNeedsDisable(builtin)
        }
        _builtinClosed = State(initialValue: closed)
    }

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Text("DisplayLab")
                    .font(.headline)

                Divider()

                // 内建屏开关
                Button {
                    let r = setBuiltinEnabled(builtinClosed)
                    switch r {
                    case .success(let msg): builtinClosed.toggle(); statusMessage = msg
                    case .failure(let msg): statusMessage = msg
                    }
                } label: {
                    Label(builtinClosed ? "恢复内建屏" : "关闭内建屏",
                          systemImage: builtinClosed ? "display" : "rectangle.slash")
                }

                // 值守开关
                Button {
                    if watchdog.isRunning { watchdog.stop() } else { watchdog.start() }
                } label: {
                    Label(watchdog.isRunning ? "停止值守" : "开启值守",
                          systemImage: watchdog.isRunning ? "pause.circle" : "play.circle")
                }

                Divider()

                // 状态栏
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(watchdog.lastLog)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Button("退出") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(12)
            .frame(width: 260)
        } label: {
            Image(systemName: builtinClosed ? "rectangle.slash" : "display")
        }
    }
}
