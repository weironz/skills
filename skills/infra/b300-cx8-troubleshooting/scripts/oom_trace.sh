#!/usr/bin/env bash
# oom_trace.sh — 只读：从故障所在 boot 的 OOM 追到进程、cgroup、容器与资源配置
# 用法: ssh root@host 'bash -s -- <boot> [since] [until]' < oom_trace.sh
#   boot  : journalctl 的 boot 偏移或 boot ID（如 -3 或 <boot-id>）
#   since/until 可选，例如 "2026-11-01 17:00" "2026-11-01 17:10"
set -u
B=${1:?需要 boot 偏移或 boot ID，例如 -3}
SINCE=${2:-}; UNTIL=${3:-}
J=(journalctl -k -b "$B" --no-pager); [ -n "$SINCE" ] && J+=(--since "$SINCE"); [ -n "$UNTIL" ] && J+=(--until "$UNTIL")
sec(){ printf '\n===== %s =====\n' "$1"; }
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
"${J[@]}" > "$TMP" 2>/dev/null

sec "OOM 事件"
grep -E "page allocation failure|invoked oom-killer|oom-kill:|Out of memory: Killed" "$TMP" | cut -c1-400
echo
echo "提示: constraint=CONSTRAINT_MEMORY_POLICY 或 CONSTRAINT_CPUSET → NUMA/cpuset 局部 OOM（整机不一定满）"
echo "      global_oom 且容器没有设内存上限 → 超量内存拖垮整机"

sec "OOM 时 RSS 最大的 10 个进程（单位 GiB）"
# 任务表行格式: [  pid  ]   uid  tgid total_vm rss rss_anon rss_file rss_shmem pgtables swapents oom_score_adj name
grep -E "kernel: \[ *[0-9]+\] +[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+" "$TMP" | sed -E 's/.*kernel: \[ *([0-9]+)\] +/\1 /' \
 | awk '{pid=$1; rss=$5; name=$NF; if(!(pid in s)||rss>s[pid]){s[pid]=rss; nm[pid]=name}} END{for(p in s) printf "%.2f %s %s\n", s[p]*4096/2^30, p, nm[p]}' \
 | sort -rn | head -10

sec "OOM 时各节点内存"
grep -E "Node [0-9]+ Normal free:|Node [0-9]+ active_anon" "$TMP" | cut -c1-220 | awk '!s[$0]++' | head -12
grep -E "pages RAM|Free swap|Total swap|total pagecache pages" "$TMP" | awk '!s[$0]++' | head -6

sec "cgroup → 容器"
ids=$(grep -oE "docker-[0-9a-f]{12,64}\.scope" "$TMP" | sort -u | sed -E 's/docker-([0-9a-f]+)\.scope/\1/')
[ -z "$ids" ] && echo "（OOM 中没有 docker cgroup；检查 task_memcg / system.slice 下其他服务）"
for id in $ids; do
  echo "--- container ${id:0:12}"
  if command -v docker >/dev/null; then
    docker inspect "$id" 2>/dev/null | python3 -c '
import json,sys,re
try: c=json.load(sys.stdin)[0]
except Exception: print("  docker inspect 失败（容器可能已删除）"); sys.exit()
h=c["HostConfig"]; cf=c["Config"]; st=c["State"]
print("  name=%s image=%s status=%s exit=%s oomkilled=%s"%(c["Name"],cf.get("Image"),st.get("Status"),st.get("ExitCode"),st.get("OOMKilled")))
print("  started=%s finished=%s (UTC)"%(st.get("StartedAt"),st.get("FinishedAt")))
for k in ["Memory","MemorySwap","CpusetCpus","CpusetMems","ShmSize","Privileged","CapAdd","IpcMode","NetworkMode"]:
    print("  %s=%s"%(k,h.get(k)))
print("  entrypoint=%s cmd=%s"%(cf.get("Entrypoint"),cf.get("Cmd")))
for m in c.get("Mounts",[]): print("  mount %s -> %s"%(m.get("Source"),m.get("Destination")))
print("  upperdir=%s"%c.get("GraphDriver",{}).get("Data",{}).get("UpperDir"))
for e in cf.get("Env") or []:
    k=e.split("=",1)[0]
    if k.startswith("NV_") or k in ("NCCL_VERSION",): continue
    if re.search(r"MEM|SEGMENT|NUMA|HCA|DEVICE|MOONCAKE|SGLANG|NCCL|CUDA_VISIBLE",k) and not re.search(r"KEY|TOKEN|SECRET|PASS|LICENSE",k,re.I):
        print("  env",e[:160])
'
  fi
  # 自动在容器挂载目录和可写层里找业务启动脚本/日志（devpod 场景下参数只在这里）
  if command -v docker >/dev/null; then
    dirs=$(docker inspect "$id" --format '{{range .Mounts}}{{.Source}} {{end}}{{.GraphDriver.Data.UpperDir}}' 2>/dev/null | tr ' ' '\n' | grep -vE '^$|^/dev|^/sys|^/proc|models')
    echo "  [scan] 在以下目录查找启动脚本/日志: $(echo $dirs)"
    timeout 90 find $dirs -xdev -maxdepth 4 -type f \( -name '*.sh' -o -name '*.log' \) -size -50M 2>/dev/null \
      | grep -vE '/(site-packages|node_modules|\.cache|\.triton|cache)/' \
      | xargs -r grep -lsE 'launch_server|numactl|SEGMENT_SIZE|Mounting segment|--mem-fraction|hicache|mooncake_store' 2>/dev/null | head -20 \
      | while read -r f; do
          echo "  [file] $(ls -l --time-style=+%F_%T "$f" | awk '{print $6, $7}')"
          grep -hoE '(numactl [^|;]*|[A-Z_]*SEGMENT_SIZE=[0-9]+|Mounting segment[^,]*, [0-9]+ of [0-9]+ total|--mem-fraction-static [0-9.]+|--enable-hierarchical-cache|--hicache-[a-z-]+ [^ ]+)' "$f" 2>/dev/null | sort | uniq -c | sort -rn | head -6 | sed 's/^/         /'
        done
  fi
done

sec "下一步（手工）"
cat <<'EOF'
1. entrypoint 是 sleep/devpod 时，业务是登录进容器手动启动的：去 mounts 和 upperdir 里找 *.sh / *.log
     grep -rlsE "launch_server|segment|numactl|--mem|hicache" <mount源目录> <upperdir> 2>/dev/null
2. 从业务日志里取实际生效的参数（不要只看脚本，脚本可能在事后被改过；用 ls -l --time-style=full-iso 看修改时间）
3. 算账：锁定/注册内存 + host pool + 加载峰值，和对应 NUMA 节点组的容量（numactl -H）对比
EOF
