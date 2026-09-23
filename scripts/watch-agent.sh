#!/bin/bash
# watch-agent.sh —— 安装 / 卸载 displaylab 的内建屏自动值守 LaunchAgent
#
# 用途：登录后常驻一个进程，检测到内建屏被系统恢复（唤醒/解锁/显示器重算）时，
#       自动重新把它关掉，让「内建屏保持关闭」这个状态不再一觉醒来就失效。
#
# 设计要点（对应 AGENTS.md 的约束）：
#   · 只跑用户级 LaunchAgent（~/Library/LaunchAgents），不碰系统目录、不需要 root、不关 SIP。
#   · 值守逻辑本体是 `displaylab watch`，这里只负责「装/卸」这个常驻进程的托管。
#   · 可逆：uninstall 即彻底移除，机器回到没有值守的原始状态。
#
# 用法：
#   scripts/watch-agent.sh install   安装（加载 LaunchAgent，立即生效）
#   scripts/watch-agent.sh uninstall 卸载（停止并移除）
#   scripts/watch-agent.sh status    查看当前状态

set -euo pipefail

LABEL="com.displaylab.watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# 优先用已安装到 /usr/local/bin 的二进制；否则回退到仓库里的 build 产物。
BIN="$(command -v displaylab || true)"
if [ -z "$BIN" ]; then
    BIN="$(cd "$(dirname "$0")/.." && pwd)/build/displaylab"
fi
LOG_DIR="$HOME/Library/Logs/displaylab"
STDOUT_LOG="$LOG_DIR/watch.out.log"
STDERR_LOG="$LOG_DIR/watch.err.log"

write_plist() {
    mkdir -p "$LOG_DIR"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>watch</string>
        <string>--interval</string>
        <string>3</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>ProcessType</key>
    <string>Interactive</string>

    <key>StandardOutPath</key>
    <string>$STDOUT_LOG</string>

    <key>StandardErrorPath</key>
    <string>$STDERR_LOG</string>
</dict>
</plist>
EOF
}

install() {
    if [ ! -x "$BIN" ]; then
        echo "找不到 displaylab 二进制（$BIN）。请先 make cli 或 make install。" >&2
        exit 1
    fi
    echo "使用二进制：$BIN"
    write_plist

    # 先卸载旧的（若有），避免重复加载报错。
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

    # 尝试立即加载。某些非交互 shell（如通过 agent / 远程执行）没有往 GUI 域
    # 注册 job 的权限，会得到 "Bootstrap failed: 5"。此时 plist 已经就位，
    # 下次登录 launchd 会自动加载，等价于"已安装"。
    if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
        launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true
        echo "已安装并启动。"
    else
        echo "plist 已写入 ${PLIST}，但当前 shell 无法立即加载（无 GUI 域 bootstrap 权限）。"
        echo "下一次登录会由 launchd 自动加载并启动，无需再手动操作。"
        echo "若想立即生效，请在「终端」App 里手动执行："
        echo "    launchctl bootstrap gui/\$(id -u) $PLIST"
    fi
    echo "日志：$STDOUT_LOG / $STDERR_LOG"
    echo "卸载：scripts/watch-agent.sh uninstall"
}

uninstall() {
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "已卸载（停止进程并移除 plist）。"
}

status() {
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
        echo "状态：已加载（running）"
        launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "state|pid" | head -5 || true
    else
        echo "状态：未加载"
    fi
    if [ -f "$PLIST" ]; then echo "plist：存在（$PLIST）"; else echo "plist：不存在"; fi
}

case "${1:-}" in
    install)   install ;;
    uninstall) uninstall ;;
    status)    status ;;
    *)
        echo "用法：$0 {install|uninstall|status}" >&2
        exit 64
        ;;
esac
