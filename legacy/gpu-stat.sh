#!/bin/bash
#
# gpu-stat.sh —— 读独显的真实功耗/温度/利用率（不需要 root）
#
# 数据来源：IORegistry 里 AMD 加速器节点公布的 PerformanceStatistics，
# 里面直接带 Total Power(W) / Temperature(C) / Device Utilization % / 显存频率等。
# 比 powermetrics 更省事 —— 后者在 Intel 机型上要 root，而且不一定支持 GPU 采样器。
#
# 用法：
#   ./gpu-stat.sh            打印一次
#   ./gpu-stat.sh --watch 3  每 3 秒打印一次，串流（Ctrl-C 退出）
#   ./gpu-stat.sh --avg 20   采 20 秒后输出功耗/温度的均值与极值（做 A/B 对比用这个）
#
# 典型用法：改任何设置（拔内屏排线 / 换分辨率 / 启动 MacHead / 开低功耗模式）前后
#          各跑一次 --avg 20，比较平均功耗与温度。

set -u
WATCH=0
AVG=0
case "${1:-}" in
  --watch) WATCH="${2:-3}" ;;
  --avg)   AVG="${2:-20}" ;;
esac

sample() {
  local stats
  stats=$(ioreg -l -w0 2>/dev/null \
          | grep -A40 'AMDRadeonX6000_AMDNavi14GraphicsAccelerator  <class' \
          | grep -m1 '"PerformanceStatistics"')

  if [ -z "$stats" ]; then
    echo "读不到 AMD 加速器统计 —— 独显可能未上电（这本身是个好消息）。"
    return
  fi

  local power temp util act core mem
  power=$(printf '%s' "$stats" | grep -o '"Total Power(W)"=[0-9]*'    | head -1 | cut -d= -f2)
  temp=$(printf '%s'  "$stats" | grep -o '"Temperature(C)"=[0-9]*'    | head -1 | cut -d= -f2)
  util=$(printf '%s'  "$stats" | grep -o '"Device Utilization %"=[0-9]*' | head -1 | cut -d= -f2)
  act=$(printf '%s'   "$stats" | grep -o '"GPU Activity(%)"=[0-9]*'   | head -1 | cut -d= -f2)
  core=$(printf '%s'  "$stats" | grep -o '"Core Clock(MHz)"=[0-9]*'   | head -1 | cut -d= -f2)
  mem=$(printf '%s'   "$stats" | grep -o '"Memory Clock(MHz)"=[0-9]*' | head -1 | cut -d= -f2)

  printf '%s  独显功耗 %2s W   温度 %2s°C   利用率 %2s%%   活动 %2s%%   核心 %4s MHz / 显存 %4s MHz\n' \
    "$(date '+%H:%M:%S')" "${power:-?}" "${temp:-?}" "${util:-?}" "${act:-?}" "${core:-?}" "${mem:-?}" \
    | sed 's/  \([0-9]\)/ \1/g'
}

echo "── 独显实时状态（来源：IORegistry PerformanceStatistics）──"

if [ "$AVG" != "0" ]; then
  # 取平均：把 N 次采样的功耗/温度累计，最后输出均值与极值。
  # 单次读数在 8~15W 之间乱跳（核心时钟有突发），必须平均后才有比较意义。
  n=0; ps=0; pmin=9999; pmax=0; ts=0; tmax=0; us=0
  while [ "$n" -lt "$AVG" ]; do
    stats=$(ioreg -l -w0 2>/dev/null \
            | grep -A40 'AMDRadeonX6000_AMDNavi14GraphicsAccelerator  <class' \
            | grep -m1 '"PerformanceStatistics"')
    if [ -z "$stats" ]; then echo "独显未上电（读不到统计）"; exit 0; fi
    p=$(printf '%s' "$stats" | grep -o '"Total Power(W)"=[0-9]*'       | head -1 | cut -d= -f2)
    t=$(printf '%s' "$stats" | grep -o '"Temperature(C)"=[0-9]*'       | head -1 | cut -d= -f2)
    u=$(printf '%s' "$stats" | grep -o '"Device Utilization %"=[0-9]*' | head -1 | cut -d= -f2)
    ps=$((ps + ${p:-0})); ts=$((ts + ${t:-0})); us=$((us + ${u:-0}))
    [ "${p:-0}" -lt "$pmin" ] && pmin=${p:-0}
    [ "${p:-0}" -gt "$pmax" ] && pmax=${p:-0}
    [ "${t:-0}" -gt "$tmax" ] && tmax=${t:-0}
    n=$((n + 1))
    sleep 1
  done
  printf '采样 %s 秒  平均功耗 %.1f W（最低 %s / 最高 %s）  平均温度 %.1f°C（最高 %s）  平均利用率 %.1f%%\n' \
    "$n" "$(echo "$ps $n" | awk '{printf "%.1f", $1/$2}')" "$pmin" "$pmax" \
    "$(echo "$ts $n" | awk '{printf "%.1f", $1/$2}')" "$tmax" \
    "$(echo "$us $n" | awk '{printf "%.1f", $1/$2}')"
  exit 0
fi

if [ "$WATCH" = "0" ]; then
  sample
  echo
  echo "CPU 侧限频：$(pmset -g therm 2>/dev/null | awk '/CPU_Speed_Limit/{print $3"（100 = 未降频）"}')"
else
  trap 'echo; echo "已停止采样。"; exit 0' INT TERM
  while true; do sample; sleep "$WATCH"; done
fi
