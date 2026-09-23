import Foundation
import IOKit

// MARK: - 屏幕到底挂在哪块 GPU 下
//
// 做法和 gpu-owner.sh 一样：读 IORegistry 的父子关系，而不是猜。
// 2019 16" 的 ACPI 里 GFX0 = 独显（父节点是 PEG0 这个 PCIe 显卡根端口），
// IGPU@2 = 集显。显示器节点挂在谁下面，就由谁驱动 —— 详见 docs/FINDINGS.md。

func ioClassName(_ entry: io_registry_entry_t) -> String {
    let property = IORegistryEntryCreateCFProperty(entry, "IOClass" as CFString,
                                                   kCFAllocatorDefault, 0)
    if let name = property?.takeRetainedValue() as? String { return name }
    return "?"
}

/// 节点在 IORegistry 里的名字（EGP0@0、GFX0@0、ATY,Boa@0 …）。
/// 有些中间节点没有 IOClass 属性，必须退回 IORegistryEntryGetName 才能显示出路径。
func ioNodeName(_ entry: io_registry_entry_t) -> String {
    var buffer = [CChar](repeating: 0, count: 128)
    let result = buffer.withUnsafeMutableBufferPointer { pointer in
        IORegistryEntryGetName(entry, pointer.baseAddress)
    }
    if result == KERN_SUCCESS, buffer[0] != 0, let name = String(validatingUTF8: buffer) {
        return name
    }
    return ioClassName(entry)
}

/// 从某个节点一路向上收敛到根，返回经过的节点名链（含自身）。
func classChain(of entry: io_registry_entry_t) -> [String] {
    var chain: [String] = []
    var current = entry
    IOObjectRetain(current)
    while true {
        chain.append(ioNodeName(current))
        var parent: io_registry_entry_t = 0
        let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
        IOObjectRelease(current)
        guard result == KERN_SUCCESS, parent != 0 else { break }
        current = parent
    }
    return chain
}

func gpuOwner(ofChain chain: [String]) -> String {
    for className in chain {
        if className.contains("AMDRadeon") || className.contains("ATY,") {
            return "独显 AMD Radeon Pro 5300M"
        }
        if className.contains("IntelFramebuffer") || className.contains("IntelAccelerator") {
            return "集显 Intel UHD 630"
        }
    }
    return "未知"
}

/// 遍历所有显示器服务，返回「显示器类名 + 驱动它的 GPU + 父链」。
func displayOwnership() -> [(display: String, owner: String, chain: [String])] {
    var results: [(String, String, [String])] = []
    for matchingClass in ["IODisplay", "AppleDisplay"] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching(matchingClass),
                                           &iterator) == KERN_SUCCESS else { continue }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let chain = classChain(of: service)
            IOObjectRelease(service)
            let displayClass = chain.first ?? "?"
            // AppleDisplay / AppleBacklightDisplay / AppleExternalDisplay 都算显示器；
            // 内建屏对外不暴露窗口服务名字，这里只能靠类名区分。
            if displayClass.hasPrefix("AppleDisplay") || displayClass.hasPrefix("AppleBacklightDisplay")
                || displayClass.hasPrefix("AppleExternalDisplay") {
                let owner = gpuOwner(ofChain: chain)
                if !results.contains(where: { $0.0 == displayClass && $0.1 == owner }) {
                    results.append((displayClass, owner, chain))
                }
            }
            service = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)
        if !results.isEmpty { break }
    }
    return results
}

/// 读 gMux（硬件切换器）的状态。
func muxStatus() -> [String: String] {
    var output: [String: String] = [:]
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                       IOServiceMatching("AppleMuxControl"),
                                       &iterator) == KERN_SUCCESS else { return output }
    defer { IOObjectRelease(iterator) }
    guard let service = Optional(IOIteratorNext(iterator)), service != 0 else { return output }
    defer { IOObjectRelease(service) }

    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return output }

    if let active = dictionary["ActiveGPU"] as? String { output["ActiveGPU"] = active }
    if let version = dictionary["gMux-version"] as? String { output["gMux 版本"] = version }
    if let policy = dictionary["policy"] as? NSNumber {
        output["切换策略 policy"] = "\(policy.intValue)（2 = 自动切换）"
    }
    if let external = dataToInt(dictionary["ExternalDisplayPresent"]) {
        output["检测到外接屏"] = external != 0 ? "是" : "否"
    }
    if let switches = dataToInt(dictionary["SwitchCount"]) {
        output["上电以来 mux 切换次数"] = "\(switches)"
    }
    return output
}

func cmdWho() {
    print("【屏幕信号通路】")
    let ownership = displayOwnership()
    if ownership.isEmpty {
        print("  读不到显示器服务 —— 用 gpu-owner.sh（基于 ioreg 树）复核。")
    }
    for entry in ownership {
        print("  \(entry.display)  =>  \(entry.owner)")
        let chain = entry.chain.prefix(8).joined(separator: " > ")
        print("      \(chain) …")
    }
    print()

    print("【gMux 硬件切换器】")
    let mux = muxStatus()
    if mux.isEmpty {
        print("  读不到 AppleMuxControl（本机可能不是双显卡机型）")
    }
    for key in mux.keys.sorted() {
        print("  \(key)：\(mux[key]!)")
    }
    print()

    print("【电源侧设置】")
    if let gpuswitch = pmsetValue("gpuswitch") {
        let meaning = ["0": "（只集显）", "1": "（只独显）", "2": "（自动切换）"][gpuswitch] ?? ""
        print("  gpuswitch：\(gpuswitch)\(meaning)")
    }
    if let lowPower = pmsetValue("lowpowermode") { print("  lowpowermode：\(lowPower)") }
    print()

    print("【结论】")
    let ownedByDiscrete = ownership.contains { $0.owner.contains("独显") }
    if ownedByDiscrete {
        print("  ⚠ 有屏幕由独显驱动 → 独显处于常开状态。")
        print("    2019 16\" 的对外视频通道物理上接在独显侧，外接屏一插独显就必须上电，")
        print("    空载即 10 W 上下（用 `displaylab gpu` 实测），这就是发烫的主因。")
    } else if !ownership.isEmpty {
        print("  ✓ 屏幕全部由集显驱动，独显应当可以断电。")
    } else {
        print("  未能判定，请用 scripts/gpu-owner.sh 复核。")
    }
}
