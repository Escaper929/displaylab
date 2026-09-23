import AppKit

// 生成 DisplayLab 菜单栏图标（一个带斜杠的显示器，呼应"关内建屏"的主题）
// 用纯 AppKit 绘制，不依赖任何设计工具。

let size = NSSize(width: 512, height: 512)
let image = NSImage(size: size)
image.lockFocus()

// 圆角矩形背景
let bgRect = NSRect(x: 0, y: 0, width: 512, height: 512)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 96, yRadius: 96)
NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1).setFill()
bgPath.fill()

// 显示器外框
let screenRect = NSRect(x: 96, y: 160, width: 320, height: 208)
let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 16, yRadius: 16)
NSColor(calibratedWhite: 0.92, alpha: 1).setStroke()
screenPath.lineWidth = 22
screenPath.stroke()

// 屏幕内部填充（蓝灰色调）
let innerRect = screenRect.insetBy(dx: 22, dy: 22)
let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: 8, yRadius: 8)
NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.85, alpha: 1).setFill()
innerPath.fill()

// 支架
let standPath = NSBezierPath()
standPath.move(to: NSPoint(x: 256, y: 160))
standPath.line(to: NSPoint(x: 256, y: 96))
standPath.lineWidth = 22
NSColor(calibratedWhite: 0.92, alpha: 1).setStroke()
standPath.stroke()

let basePath = NSBezierPath()
basePath.move(to: NSPoint(x: 176, y: 96))
basePath.line(to: NSPoint(x: 336, y: 96))
basePath.lineWidth = 22
basePath.stroke()

// 斜杠（表示"关闭"）
let slashPath = NSBezierPath()
slashPath.move(to: NSPoint(x: 120, y: 400))
slashPath.line(to: NSPoint(x: 392, y: 128))
NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.30, alpha: 1).setStroke()
slashPath.lineWidth = 26
slashPath.lineCapStyle = .round
slashPath.stroke()

image.unlockFocus()

// 保存 PNG（多尺寸）
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("生成失败")
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "DisplayLab.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("已生成 \(outPath)")
