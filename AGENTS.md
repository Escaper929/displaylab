# AGENTS.md

给接手这个项目的人（或 AI）的笔记。保持简短、保持最新。

## 这是什么

研究并控制**无头 MacBook**（面板被拆掉、只剩内屏排线、长期外接屏）的显示通路：
画面由哪块 GPU 驱动、那条"通向不存在的屏"的通路在花什么钱、以及哪些改动真的有意义。
硬件事实与证据见 [`docs/FINDINGS.md`](docs/FINDINGS.md)，读代码前先读它。

## 布局

```
Sources/DisplayLab/
  main.swift         子命令分发（一个二进制，全部走 CLI）
  Displays.swift     显示器枚举、标志位、模式与负载估算、私有 API 开关屏
  GPUTelemetry.swift 独显遥测（IORegistry / IOAccelerator）
  Who.swift          屏幕归属 + gMux 状态
  Support.swift      pmset 读取、Data→Int 等小工具
scripts/
  gpu-owner.sh       基于 ioreg 缩进树的显卡归属诊断（Who.swift 的交叉验证实现）
  force-igpu-test.sh 实测 gpuswitch 0，带 trap 自动回滚
docs/
  FINDINGS.md        已验证事实 + 复现命令
  PRIVATE-CG.md      CGSConfigureDisplayEnabled 调用约定与坑
  MACHEAD.md         对 MacHead.app 的逆向笔记
```

## 构建

```bash
make            # -> build/displaylab
make install    # -> /usr/local/bin/displaylab
make who list gpu
```

**没有包管理器、没有第三方依赖**，只要 Xcode Command Line Tools。保持这样。

## 不太显然的约束

1. **一个二进制、多个子命令。** 不要拆成多个可执行文件，脚本与文档都按单一入口写。
2. **私有符号一律 `dlopen` + `dlsym` 动态解析**，并优雅降级到"提示 + 非零退出"。
   不要编译期链接 SkyLight——符号将来可能消失，静态链接会让整个工具起不来。
3. **`CGDisplayIsActive` 不是"是否被启用"**。实测它对内建屏恒为 `false`，且
   `CGSConfigureDisplayEnabled(id, true)` 也不会让它翻转。别拿它做判断依据。
4. **关屏的安全阀不能用"在线屏总数"判断**。目标屏本身可能已经"在线但不出画"，
   那样计数只剩 1，会把正常情况误判成"最后一块屏"而拒绝执行。要判"别的屏在出画"。
5. **只提交 `.forSession`。** `.permanently` 会写进系统配置，改坏了重启也回不来。
6. **估算就是估算。** `list` 里的 `Mpix/s` 是按模式算的静态值，只在 `出画=是` 时成立；
   判断真实代价一律用 `gpu` 的功耗读数。这个项目已经因为把估算当测量返工过一次
   （`FINDINGS.md` 第 7 条），不要重蹈覆辙。
7. **`PerformanceStatistics` 里混着溢出的 `UInt64` 计数**（如 `stdTextureCreationBytes`），
   整表转 `Int` 会炸。只能白名单取键 + `NSNumber.intValue`。
8. **`gpuswitch` 会持久化，重启不还原。** `force-igpu-test.sh` 里的交互确认与自动回滚是
   故意的，不要为了"自动化"把它去掉。动这个设置前必须先能 SSH 进来。
9. **不要给只读诊断加副作用。** `who` / `list` / `gpu` 必须永远不改变系统状态。
10. **跨项目边界**：keyglow 控制的键盘背光在 Top Case 总线上（VID `0x05AC` / PID `33026`，
    UsagePage `0xFF00` / Usage `15`），与本项目的 eDP 显示排线无关。拔显示排线不影响它。
11. `gpu-owner.sh` 与 `Who.swift` 是**两份独立实现**，故意保留：一条走 `ioreg` 文本缩进树，
    一条走 IOKit 对象遍历。两者结论不一致时，以 `ioreg` 原始输出为准并记录差异。
