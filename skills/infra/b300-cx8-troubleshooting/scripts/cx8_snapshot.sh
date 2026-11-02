#!/usr/bin/env bash
# cx8_snapshot.sh — B300 CX8 只读现状采集与按层分类
# 用法: ssh root@host 'bash -s' < cx8_snapshot.sh            # 默认
#       ssh root@host 'bash -s -- --fw' < cx8_snapshot.sh     # 额外做 flint 查询（每卡最多 20s）
# 只读：不加载/卸载模块、不复位、不改配置。
set -u
WANT_FW=0; [ "${1:-}" = "--fw" ] && WANT_FW=1
EXPECTED=${CX8_EXPECTED:-8}
sec(){ printf '\n===== %s =====\n' "$1"; }
have(){ command -v "$1" >/dev/null 2>&1; }

sec "HOST"
echo "host=$(hostname) kernel=$(uname -r) uptime=$(uptime -p 2>/dev/null)"
have ofed_info && echo "ofed=$(ofed_info -s 2>/dev/null)"
have mst && mst version 2>/dev/null | head -1

sec "BOOTS (最后 5 次；故障往往在更早的 boot)"
journalctl --list-boots --no-pager 2>/dev/null | tail -5

sec "CX8 PER-DEVICE"
mapfile -t BDFS < <(lspci -D -d 15b3:1023 2>/dev/null | awk '{print $1}')
echo "enumerated=${#BDFS[@]} expected=$EXPECTED"
bound=0; ibcnt=0; active=0
for d in "${BDFS[@]}"; do
  p=/sys/bus/pci/devices/$d
  drv=$(basename "$(readlink "$p/driver" 2>/dev/null)" 2>/dev/null); [ "$drv" = "." ] && drv=""
  ib=$(ls "$p/infiniband" 2>/dev/null | head -1)
  st=""; ph=""; rt=""
  if [ -n "$ib" ]; then
    st=$(cat /sys/class/infiniband/$ib/ports/1/state 2>/dev/null)
    ph=$(cat /sys/class/infiniband/$ib/ports/1/phys_state 2>/dev/null)
    rt=$(cat /sys/class/infiniband/$ib/ports/1/rate 2>/dev/null)
    ibcnt=$((ibcnt+1)); case "$st" in *ACTIVE*) active=$((active+1));; esac
  fi
  [ "$drv" = "mlx5_core" ] && bound=$((bound+1))
  printf '%s drv=%-9s link=%sx%s numa=%s ib=%-8s state=%s phys=%s rate=%s\n' "$d" "${drv:-NONE}" \
    "$(cat $p/current_link_speed 2>/dev/null | tr -d ' ')" "$(cat $p/current_link_width 2>/dev/null)" \
    "$(cat $p/numa_node 2>/dev/null)" "${ib:--}" "${st:--}" "${ph:--}" "${rt:--}"
done
echo "summary: enumerated=${#BDFS[@]} bound=$bound ib_devices=$ibcnt active=$active"

sec "OTHER MLX DEVICES (BF3 管理网 / CX7 bridge)"
lspci -Dnn -d 15b3: 2>/dev/null | grep -vE "15b3:(1023|197c)\]" | cut -c1-120
ls /sys/class/infiniband 2>/dev/null | tr '\n' ' '; echo

PAT='pre-initializing|probe of .* failed|mlx5_init_one failed|irisc not responding|health compromised|synd 0x|ext_synd|timeout\. Will cause a leak|Fatal error|Port module event|Cable (un)?plugged|AER|firmware version'
for b in 0 -1; do
  sec "MLX5 KEY KERNEL LOG boot $b (去重，前 40 条)"
  journalctl -k -b $b --no-pager 2>/dev/null | grep -E "mlx5_core|pcieport" | grep -v "_OSC" | grep -E "$PAT" \
    | sed -E 's/\(pid [0-9]+\)//' | awk '{k=$0; sub(/^[A-Z][a-z]{2} [0-9 ]+ [0-9:]+ /,"",k); sub(/[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]/,"BDF",k); if(!s[k]++) print}' \
    | cut -c1-230 | head -40
done

sec "FIRST HEALTH EVENT IN RETAINED BOOTS (定位 T0)"
for b in $(journalctl --list-boots --no-pager 2>/dev/null | awk 'NR>1{print $1}' | tail -6); do
  first=$(journalctl -k -b "$b" --no-pager 2>/dev/null | grep -m1 -E "irisc not responding|health compromised|pre-initializing")
  [ -n "$first" ] && echo "boot $b: ${first:0:200}"
done

sec "OOM / PAGE ALLOC FAILURE (boot 0 与之前 3 次)"
for b in 0 -1 -2 -3; do
  journalctl -k -b $b --no-pager 2>/dev/null | grep -E "oom-kill:|Out of memory: Killed|page allocation failure" \
    | cut -c1-260 | head -4 | sed "s/^/[boot $b] /"
done

sec "NUMA MEMORY"
for n in /sys/devices/system/node/node[0-9]*; do
  awk -v n="$(basename $n)" '/MemTotal/{t=$4}/MemFree/{f=$4}END{printf "%s total=%.0fGiB free=%.0fGiB (%.0f%%)\n",n,t/1048576,f/1048576,(t?100*f/t:0)}' $n/meminfo
done
sysctl -n vm.overcommit_memory vm.min_free_kbytes kernel.numa_balancing 2>/dev/null | paste -sd' ' | sed 's/^/overcommit min_free_kbytes numa_balancing = /'

sec "GPU"
if have nvidia-smi; then
  echo "gpu_count=$(timeout 60 nvidia-smi -L 2>/dev/null | grep -c '^GPU')"
  timeout 60 nvidia-smi -q 2>/dev/null | grep -A2 -E "^\s+Fabric" | grep -E "State|Status" | sort | uniq -c
fi
systemctl is-active nvidia-fabricmanager 2>/dev/null | sed 's/^/fabricmanager=/'
systemctl is-active openibd 2>/dev/null | sed 's/^/openibd=/'

if [ $WANT_FW = 1 ] && have flint; then
  sec "FW QUERY (flint q, 每卡 20s 超时)"
  for d in "${BDFS[@]}"; do echo "$d: $(timeout 20 flint -d $d q 2>&1 | grep -E 'FW Version|-E-' | head -1)"; done
fi

sec "LAYER CLASSIFICATION (初判，仅供参考)"
n=${#BDFS[@]}
if [ "$n" -lt "$EXPECTED" ]; then
  echo "L1 PCIe 枚举：只枚举到 $n/$EXPECTED 块 CX8 → references/pcie-enumeration.md（同时看 GPU 是否也缺）"
elif [ "$bound" -lt "$n" ]; then
  echo "L2 驱动/固件初始化：$((n-bound))/$n 块未绑定驱动 → references/firmware-hang.md"
  echo "   若之前已软重启过仍失败，通常需要冷断电；先在更早的 boot 里找 T0 和触发源。"
elif [ "$ibcnt" -lt "$n" ]; then
  echo "L3 RDMA 栈：驱动已绑定，但 IB 设备只有 $ibcnt/$n → 检查 mlx5_ib / openibd"
elif [ "$active" -lt "$n" ]; then
  echo "L4/L5 端口：$((n-active))/$n 个端口非 ACTIVE → references/port-down.md（看 phys 状态和共性）"
else
  echo "端口层正常：问题在拓扑/性能/业务层 → references/topology-perf.md"
fi
