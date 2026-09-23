import Foundation

// displaylab —— 无头 MacBook 的显示通路研究与控制工具
//
// 一个二进制，多个子命令（与 keyglow 同样的约定：无参数不启动 GUI，全部走 CLI）。
// 每个子命令只做一件事，全部遵循「只读优先、改动会话级」的原则。

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
let options = Array(arguments.dropFirst())

func printHelp() {
    print("""
    displaylab —— 无头 MacBook 的显示通路研究与控制

    用法：displaylab <子命令> [参数]

      who                屏幕由哪块 GPU 驱动 + gMux 状态 + gpuswitch（只读）
      list               显示器清单：标志位、镜像关系、扫描负载（只读）
      gpu [--avg N] [--watch N]
                         独显遥测：功耗 / 温度 / 利用率（只读，不需要 root）
      off                关闭内建屏（内建屏不出画时用它保持关闭）
      on                 恢复内建屏
      help               本帮助

    安全约定：
      · off / on 只作用于内建屏，且用 kCGConfigureForSession 提交 —— 注销或重启自动复原。
      · 当除了内建屏之外没有别的屏在出画时，off 会拒绝执行。
      · 所有只读子命令都不会改动任何系统状态。
    """)
}

switch command {
case "who":            cmdWho()
case "list":           cmdList()
case "gpu":            cmdGPU(options)
case "off":            cmdSetBuiltin(false)
case "on":             cmdSetBuiltin(true)
case "help", "-h", "--help": printHelp()
default:
    print("未知子命令：\(command)\n")
    printHelp()
    exit(64)
}
