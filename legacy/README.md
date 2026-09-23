# legacy —— 被 displaylab 取代的早期实现

这些是立项前在 keyglow 仓库里临时写的原型，功能已全部并入 `build/displaylab`
（`list` / `gpu` / `off` / `on`）。**不删除，留作对照**：

| 文件 | 现在对应 |
|---|---|
| `DisplayTools.swift` | `displaylab list`（显示器清单与负载估算） |
| `headless-display.swift` | `displaylab off` / `on`（私有 API 关屏） |
| `gpu-stat.sh` | `displaylab gpu --avg N`（独显遥测） |
| `bin/` | 早期编译产物，可直接删 |

两个 shell 工具没有并入：`scripts/gpu-owner.sh`（ioreg 树归属诊断）和
`scripts/force-igpu-test.sh`（gpuswitch 实测 + 自动回滚）——它们必须用 shell 才顺手。
