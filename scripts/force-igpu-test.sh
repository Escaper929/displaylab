#!/bin/bash
#
# force-igpu-test.sh —— 试用「只用集成显卡」，并保证会自动回滚
#
# 背景：这台是 MacBookPro16,1（2019 16"）。它的对外视频通道在硬件上接在独显侧，
#       所以外接屏绝大多数情况下没法改由集显驱动。本脚本用来实测一句话结论：
#       「切到集显后，外接屏还在不在」——而不是靠道听途说。
#
# 危险点（必须先读）：
#   * 外接屏是你唯一的屏幕。若切换后外接屏黑掉，你将看不见任何画面。
#   * gpuswitch 会持久化，重启也不会自动恢复。
#   因此：
#     1) 先在「系统设置 → 通用 → 共享 → 远程登录」打开 SSH，
#        并确认能从另一台电脑 ssh 进来；一旦黑屏，用
#          ssh 用户@本机IP  sudo pmset -a gpuswitch 2
#        即可救回。
#     2) 本脚本自带倒计时自动回滚（trap），即使黑屏也会在窗口结束后自己还原。
#        跑的时候不要关掉这个终端窗口，也不要 Ctrl-C 之外地强杀它。
#
# 用法：
#   sudo ./force-igpu-test.sh [窗口秒数]     默认 90 秒
#   sudo pmset -a gpuswitch 2                收工后手动确认还原（= 自动切换）
#
set -u
WINDOW="${1:-90}"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="/tmp/force-igpu-test.$STAMP.log"

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root：sudo $0 $WINDOW"
  exit 1
fi

# 判断外接屏当前挂在哪块 GPU 下
owner_of_displays() {
  ioreg -l -w0 2>/dev/null | awk '
    {
      p = index($0, "+-o ")
      if (p > 0) {
        d = int((p - 1) / 2)
        rest = substr($0, p + 4)
        split(rest, a, " ")
        name = a[1]
        path[d] = name
        if (name ~ /^(AppleDisplay|AppleBacklightDisplay)$/) {
          gpu = "?"
          for (i = 0; i <= d; i++) {
            if (path[i] ~ /AMDRadeon|ATY,/) gpu = "dGPU"
            if (path[i] ~ /IGPU@2|AppleIntelFramebuffer|IntelAccelerator/) gpu = "iGPU"
          }
          printf "%s=%s ", name, gpu
        }
      }
    }'
}

say() { echo "[$(date +%H:%M:%S)] $*"; echo "[$(date +%H:%M:%S)] $*" >>"$LOG"; }

ORIG=$(pmset -g | awk '/gpuswitch/{print $2}')
say "原始 gpuswitch = ${ORIG:-未知}（2 = 自动切换）"
pmset -a gpuswitch 2 >/dev/null 2>&1   # 统一以"自动"作为回滚目标

revert() {
  pmset -a gpuswitch 2 >/dev/null 2>&1
  say "已回滚：gpuswitch = 2（自动切换）。日志：$LOG"
}
trap revert EXIT INT TERM

cat <<EOF
────────────────────────────────────────────────────────────
即将强制切到「只用集成显卡」并观察 ${WINDOW} 秒。

  切换前 : $(owner_of_displays)
  外接屏是唯一屏幕 → 若黑屏，${WINDOW} 秒后脚本会自动还原，请耐心等。

确认已能从另一台机器 SSH 进来，再继续。
────────────────────────────────────────────────────────────
EOF
printf '输入 yes 继续（30 秒无输入则放弃）：'
read -r -t 30 ANS || ANS=""
case "$ANS" in
  yes|YES|y|Y) ;;
  *) say "未确认，退出，未做任何改动。"; exit 0 ;;
esac

say "写入 gpuswitch = 0 …"
pmset -a gpuswitch 0
sleep 4
AFTER=$(owner_of_displays)
say "切换后 : $AFTER"

RESULT="unknown"
case "$AFTER" in
  *"AppleDisplay=iGPU"*) RESULT="ok" ;;
  *"AppleDisplay=dGPU"*) RESULT="ineffective" ;;
  *"AppleDisplay="*)     RESULT="black" ;;
  *)                     RESULT="black" ;;
esac

case "$RESULT" in
  ok)
    say "✓ 外接屏已改由集显驱动 —— 硬件上可行！"
    say "  接下来 ${WINDOW} 秒会持续观察；结束后你可以选择保留这个设置。"
    ;;
  ineffective)
    say "✗ 外接屏仍由独显驱动 —— macOS 忽略了 gpuswitch 0。"
    say "  这条路在这台机器上走不通，${WINDOW} 秒后自动还原。"
    ;;
  *)
    say "✗ 外接屏节点消失了 —— 大概率就是黑屏，硬件决定它只能走独显。"
    say "  等 ${WINDOW} 秒自动还原即可；急的话从另一台机器 ssh 过来执行"
    say "    sudo pmset -a gpuswitch 2"
    ;;
esac

# 窗口期内持续采样，记录屏幕归属是否稳定
END=$(( $(date +%s) + WINDOW ))
while [ "$(date +%s)" -lt "$END" ]; do
  sleep 10
  say "采样   : $(owner_of_displays)  gpuswitch=$(pmset -g | awk '/gpuswitch/{print $2}')"
done

if [ "$RESULT" = "ok" ]; then
  printf '保留「只用集显」吗？(y/N，20 秒无输入则还原)：'
  read -r -t 20 KEEP || KEEP=""
  case "$KEEP" in
    y|Y)
      trap - EXIT
      say "保留 gpuswitch = 0。想改回自动：sudo pmset -a gpuswitch 2"
      exit 0
      ;;
  esac
fi
say "准备还原。"
