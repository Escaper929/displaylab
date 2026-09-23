import Foundation

// MARK: - 系统信息小工具
//
// 唯一需要外部命令的地方：pmset 的显卡切换与降频状态没有公开的 IOKit 读取方式，
// 只能问 pmset。它属于系统自带，不引入任何第三方依赖。

func shellOutput(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

/// 读取 `pmset -g` 里的某个键，例如 gpuswitch / lowpowermode。
func pmsetValue(_ key: String) -> String? {
    guard let output = shellOutput("/usr/bin/pmset", ["-g"]) else { return nil }
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == Substring(key) {
            return String(parts[1])
        }
    }
    return nil
}

/// CPU 侧限频（100 表示没有被热降频）。
func cpuSpeedLimit() -> String? {
    guard let output = shellOutput("/usr/bin/pmset", ["-g", "therm"]) else { return nil }
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count >= 3, parts[0] == "CPU_Speed_Limit" { return String(parts[2]) }
    }
    return nil
}

/// 把 4 字节 / 1 字节的 Data 属性转成整数（IORegistry 里的 SwitchCount 就是这种）。
func dataToInt(_ value: Any?) -> Int? {
    guard let data = value as? Data else {
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
    switch data.count {
    case 1: return Int(data[0])
    case 2: return Int(data.withUnsafeBytes { $0.load(as: UInt16.self) })
    case 4: return Int(data.withUnsafeBytes { $0.load(as: UInt32.self) })
    case 8: return Int(data.withUnsafeBytes { $0.load(as: UInt64.self) })
    default: return nil
    }
}
