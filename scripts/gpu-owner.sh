#!/bin/bash
#
# gpu-owner.sh —— 只读诊断：这台 Mac 的屏幕此刻由哪块 GPU 驱动
#
# 不改动任何系统设置，可以随时跑。回答三个问题：
#   1. 内屏 / 外接屏分别挂在集成显卡还是独立显卡下（读 IORegistry 父链路，不是猜）
#   2. gMux 当前定格在哪块 GPU、外接屏是否存在、切换过几次
#   3. 电源侧设置（gpuswitch / 低功耗模式）与热的来源归属
#
# 用法:
#   ./gpu-owner.sh            普通报告
#   sudo ./gpu-owner.sh --power   额外采样 GPU/CPU 功耗与温控（需要 root）
#
# MacBookPro16,1（2019 16"）的对外视频通道物理上接在独显侧，
# 所以"外接屏 + 只用集显"这条路大概率走不通；本脚本就是用来拿硬证据的。
#
set -u
MODE="${1:-}"

hr() { printf '%s\n' "────────────────────────────────────────────────────────────"; }

# ── 1. 机器与 OS ───────────────────────────────────────────────────────────
echo "【机器】"
MODEL=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Identifier/{print $2}')
CPU=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
printf '  型号      : %s\n' "${MODEL:-未知}"
printf '  CPU       : %s\n' "${CPU:-未知}"
printf '  macOS     : %s (%s)\n' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
echo

# ── 2. 谁能驱动屏幕：解析 IORegistry 树，看显示器挂在哪个 Framebuffer 下 ──
# ioreg 的树形输出每深一层缩进 2 个字符；用缩进栈还原父链路。
scan_displays() {
  ioreg -l -w0 2>/dev/null | awk '
    {
      p = index($0, "+-o ")
      if (p > 0) {
        d = int((p - 1) / 2)
        rest = substr($0, p + 4)
        split(rest, a, " ")
        name = a[1]
        path[d] = name
        maxd = d

        if (name ~ /^(AppleDisplay|AppleBacklightDisplay|AppleExternalDisplay|IODisplay)$/) {
          chain = ""
          gpu = "未知"
          for (i = 0; i <= d; i++) {
            chain = chain (i ? " > " : "") path[i]
            if (path[i] ~ /AMDRadeon|ATY,/)      gpu = "独显 AMD Radeon Pro 5300M"
            if (path[i] ~ /IGPU@2|AppleIntelFramebuffer|IntelAccelerator/) gpu = "集显 Intel UHD 630"
          }
          printf "  %-22s => %s\n", name, gpu
          printf "     %s\n", chain
        }
      }
    }'
}

echo "【屏幕的信号通路】(显示器节点 → 它在 IORegistry 里挂在谁下面)"
scan_displays
echo

# ── 3. gMux（硬件切换开关）状态 ───────────────────────────────────────────
echo "【gMux 硬件切换器】"
ioreg -rc AppleMuxControl -w0 2>/dev/null | sed 's/^ *[|]* *//' | awk -F' = ' '
  /"ActiveGPU"/              { gsub(/"/,"",$2); print "  当前激活 GPU        : " $2 }
  /"ExternalDisplayPresent"/ { print "  是否检测到外接屏    : " ($2 ~ /01/ ? "是" : "否") }
  /"policy"/                 { gsub(/"/,"",$2); print "  切换策略 policy     : " $2 "   (2 = 自动切换)" }
  /"SwitchCount"/            { print "  上电以来 mux 切换次数: " $2 }
  /"GPUPowered"/             { print "  GPUPowered 位图     : " $2 }
'
echo

# ── 4. 电源侧设置 ─────────────────────────────────────────────────────────
echo "【电源与显卡策略】"
pmset -g 2>/dev/null | awk '
  /gpuswitch/    { print "  gpuswitch         : " $2 "   (0=只集显 1=只独显 2=自动)" }
  /lowpowermode/ { print "  lowpowermode      : " $2 "   (1=低功耗模式已开)" }
  /displaysleep/ { print "  displaysleep      : " $2 " 分钟" }
'
pmset -g therm 2>/dev/null | awk '
  /CPU_Scheduler_Limit|CPU_Speed_Limit/ { print "  " $1 " = " $3 "   (100 = 没有降频)" }
'
echo

# ── 5. 两块 GPU 的驱动是否都活着 ──────────────────────────────────────────
AMD_ACC=$(ioreg -l -w0 2>/dev/null | grep -c '"IOClass" = "AMDRadeonX6000_AMDNavi14GraphicsAccelerator"')
INTEL_ACC=$(ioreg -l -w0 2>/dev/null | grep -c '"IOClass" = "IntelAccelerator"')
echo "【驱动实例】"
printf '  AMD Navi14 加速器实例 : %s   (>0 = 独显驱动已加载上电)\n' "$AMD_ACC"
printf '  Intel 加速器实例      : %s   (>0 = 集显驱动已加载)\n' "$INTEL_ACC"
printf '  内屏背光服务 backlightd: %s\n' "$(pgrep -q backlightd && echo 运行中 || echo 未运行)"
echo

# ── 6. 结论 ───────────────────────────────────────────────────────────────
echo "【结论】"
EXT_GPU=$(scan_displays | awk '/AppleDisplay /{sub(/.*=> /,""); print; exit}')
OWNERS=$(scan_displays | awk -F'=> ' '/=>/ {print $2}')
if printf '%s' "$OWNERS" | grep -q "独显"; then
  echo "  ⚠ 现在有屏幕由「独显 AMD Radeon Pro 5300M」驱动 → 独显处于常开状态。"
  echo "    2019 16\" 的对外视频通道物理上接在独显侧，外接屏一插独显就必须上电，"
  echo "    空载也要多耗 5~10W，这就是机身发烫的主因。"
else
  echo "  ✓ 屏幕全部由集显驱动，独显应当处于断电状态。"
fi

# ── 7. 可选：功耗/温度采样 ────────────────────────────────────────────────
if [ "$MODE" = "--power" ]; then
  echo
  echo "【功耗采样】(2 秒窗口)"
  if [ "$(id -u)" -ne 0 ]; then
    echo "  需要 root：请用 sudo ./gpu-owner.sh --power"
  else
    OUT=$(powermetrics -n 1 -i 1000 --samplers gpu_power,cpu_power,thermal 2>&1)
    if printf '%s' "$OUT" | grep -qiE "GPU Power|Package Power|CPU Power"; then
      printf '%s\n' "$OUT" | grep -iE "GPU Power|Package Power|CPU Power|Combined Power|fan|therm" | sed 's/^/  /'
    else
      echo "  本机的 powermetrics 不支持这两个采样器（Intel 机型常见）。"
      echo "  备选：安装 Stats / iStat Menus 看 GPU 功耗与风扇转速，或对比开关前后的："
      echo "    sudo powermetrics -n 3 -i 1000 --samplers smc"
      printf '%s\n' "$OUT" | head -5 | sed 's/^/  /'
    fi
  fi
fi
hr
