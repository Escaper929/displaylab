# displaylab

无头 MacBook 的显示通路研究与控制工具。

起点是一个具体问题：**一台面板被整体拆掉、只留内屏排线插在主板上、常年外接 4K 屏的
MacBook Pro 16"（2019）发热很厉害**——搞清楚它的画面到底由哪块 GPU 驱动、那条通向
"不存在的屏"的通路在花什么钱、以及有哪些真正能改的东西。

## 结论速览

| 问题 | 结论 | 依据 |
|---|---|---|
| 屏幕由谁驱动 | **独显 AMD Radeon Pro 5300M**，内屏和外接屏都挂在它下面；集显全程闲置 | `displaylab who` |
| 能改由集显驱动吗 | **不能。** 2019 16" 的对外视频通道物理上接在独显侧，外接屏一插独显就必须上电 | Apple 官方文档 + 本机 IORegistry 拓扑，见 [`docs/FINDINGS.md`](docs/FINDINGS.md) |
| 发热主因 | **独显常开**：空载 8–15 W、68–75 °C | `displaylab gpu` |
| 那条"幽灵内屏"通路 | 登记在册但**并未出画**，几乎不耗电；真正的问题是它随时可能被重新启用 | `docs/FINDINGS.md` 第 6 条 |
| 还有救的路 | ① 拔掉 eDP 排线（最干净）② MacHead 的无头模式（会同时锁休眠）③ DisplayLink 适配器（唯一能让外接屏不吃独显的方案）④ 低功耗模式（CPU 端） | `docs/FINDINGS.md` 结尾 |

## 构建

没有任何第三方依赖，也不需要包管理器——只要有 Xcode Command Line Tools：

```bash
make            # -> build/displaylab
make install    # -> /usr/local/bin/displaylab
make clean
```

## 命令

```bash
displaylab who              # 每块屏挂在哪块 GPU 下 + gMux 状态 + gpuswitch（只读）
displaylab list             # 显示器清单：标志位、镜像关系、扫描负载估算（只读）
displaylab gpu              # 独显功耗/温度/利用率，不需要 root（只读）
displaylab gpu --avg 20     # 采 20 秒取平均 —— 做 A/B 对比用这个
displaylab gpu --watch 3    # 每 3 秒串流
displaylab off / on         # 关闭 / 恢复内建屏（会话级，注销即复原）
displaylab watch            # 常驻值守：内建屏被系统恢复（唤醒/解锁）后自动重新关闭
```

`scripts/` 里还有几个 shell 工具，处理"必须用 shell 更合适"的活：

```bash
./scripts/gpu-owner.sh              # 基于 ioreg 缩进树的显卡归属诊断（who 的姊妹实现）
sudo ./scripts/force-igpu-test.sh   # 实测 gpuswitch 0（带 trap 自动回滚，跑前先开 SSH）
./scripts/watch-agent.sh install    # 安装内建屏自动值守的 LaunchAgent（登录时自动拉起 watch）
./scripts/watch-agent.sh uninstall  # 卸载（彻底恢复原状）
```

## 安全约定

这个项目会碰到"让人看不见画面"的操作，所以规则写在前面（完整版见 [`AGENTS.md`](AGENTS.md)）：

1. **永不关闭最后一块正在出画的屏。** `off` 会先检查是否还有别的屏在出画，没有就拒绝执行。
2. **只提交会话级配置**（`kCGConfigureForSession`）。注销或重启一定复原，不会把机器留在黑屏里。
3. **只有只读命令可以随便跑。** `off`/`on`/`force-igpu-test.sh` 属于会改变系统状态的操作。
4. **`gpuswitch` 会持久化，重启不还原**——这是唯一有可能把自己锁死的设置，动它之前必须先开 SSH。

## 文档

- [`docs/FINDINGS.md`](docs/FINDINGS.md) —— 这台机器上已验证的事实清单，每条都带复现命令
- [`docs/PRIVATE-CG.md`](docs/PRIVATE-CG.md) —— 用 SkyLight 私有符号真正关掉一块显示器的调用约定与坑
- [`docs/MACHEAD.md`](docs/MACHEAD.md) —— 对 MacHead.app 的逆向笔记（它用的是同一把钥匙）
