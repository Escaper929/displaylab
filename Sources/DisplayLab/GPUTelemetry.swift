import Foundation
import IOKit

// MARK: - 独显遥测（不需要 root）
//
// AMD 加速器节点会在 IORegistry 里公布一份 PerformanceStatistics 字典，
// 里面直接带功耗、温度、利用率、核心/显存频率。对比 powermetrics 的好处：
// 不需要 root，Intel 机型也能拿到。
//
// 坑：同一份字典里有些计数是 UInt64 溢出值（如 stdTextureCreationBytes），
// 所以只按白名单取键，且一律走 NSNumber.intValue，不要整表转成 Int。

let telemetryKeys = [
    "Total Power(W)",
    "Temperature(C)",
    "Device Utilization %",
    "GPU Activity(%)",
    "Core Clock(MHz)",
    "Memory Clock(MHz)",
    "Fan Speed(RPM)",
]

func amdAcceleratorStats() -> [String: Int]? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                       IOServiceMatching("IOAccelerator"),
                                       &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }

    var result: [String: Int]?
    var service = IOIteratorNext(iterator)
    while service != 0 {
        defer {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              let klass = dictionary["IOClass"] as? String,
              klass.contains("AMDRadeon"),
              let statistics = dictionary["PerformanceStatistics"] as? [String: Any]
        else { continue }

        var values: [String: Int] = [:]
        for key in telemetryKeys {
            if let number = statistics[key] as? NSNumber { values[key] = number.intValue }
        }
        if !values.isEmpty { result = values }
    }
    return result
}

func readTelemetryValue(_ stats: [String: Int]?, _ key: String) -> String {
    guard let value = stats?[key] else { return "?" }
    return String(value)
}

func telemetryLine() -> String {
    let stats = amdAcceleratorStats()
    guard stats != nil else {
        return "\(timestamp())  读不到 AMD 加速器统计 —— 独显当前未上电（这本身是个好消息）"
    }
    return String(format: "%@  独显功耗 %@ W   温度 %@°C   利用率 %@%%   活动 %@%%   核心 %@ MHz / 显存 %@ MHz",
                  timestamp(),
                  readTelemetryValue(stats, "Total Power(W)"),
                  readTelemetryValue(stats, "Temperature(C)"),
                  readTelemetryValue(stats, "Device Utilization %"),
                  readTelemetryValue(stats, "GPU Activity(%)"),
                  readTelemetryValue(stats, "Core Clock(MHz)"),
                  readTelemetryValue(stats, "Memory Clock(MHz)"))
}

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
}

func cmdGPU(_ args: [String]) {
    var avgSeconds = 0
    var watchSeconds = 0
    var index = 0
    while index < args.count {
        let value = index + 1 < args.count ? args[index + 1] : ""
        switch args[index] {
        case "--avg":   avgSeconds = Int(value) ?? 15;   index += 2
        case "--watch": watchSeconds = Int(value) ?? 3;  index += 2
        default:        index += 1
        }
    }

    print("── 独显实时状态（来源：IORegistry / IOAccelerator PerformanceStatistics）──")

    if avgSeconds > 0 {
        // 单次读数在个位数到二十几瓦之间乱跳（核心时钟有突发），必须取平均才有比较意义。
        var powerSum = 0, powerMin = Int.max, powerMax = 0
        var tempSum = 0, tempMax = 0
        var utilSum = 0
        var samples = 0
        while samples < avgSeconds {
            if let stats = amdAcceleratorStats() {
                let power = stats["Total Power(W)"] ?? 0
                let temp = stats["Temperature(C)"] ?? 0
                powerSum += power; tempSum += temp; utilSum += stats["Device Utilization %"] ?? 0
                powerMin = min(powerMin, power); powerMax = max(powerMax, power)
                tempMax = max(tempMax, temp)
                samples += 1
            } else {
                print("独显未上电（读不到统计），提前结束采样。")
                return
            }
            sleep(1)
        }
        let divisor = Double(max(samples, 1))
        print(String(format: "采样 %d 秒  平均功耗 %.1f W（最低 %d / 最高 %d）  平均温度 %.1f°C（最高 %d）  平均利用率 %.1f%%",
                     samples, Double(powerSum) / divisor, powerMin, powerMax,
                     Double(tempSum) / divisor, tempMax, Double(utilSum) / divisor))
        if let limit = cpuSpeedLimit() { print("CPU 侧限频：\(limit)（100 = 未降频）") }
        return
    }

    if watchSeconds > 0 {
        while true {
            print(telemetryLine())
            fflush(stdout)
            sleep(UInt32(watchSeconds))
        }
    }

    print(telemetryLine())
    if let limit = cpuSpeedLimit() { print("CPU 侧限频：\(limit)（100 = 未降频）") }
}
