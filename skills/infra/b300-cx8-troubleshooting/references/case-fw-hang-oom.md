# 案例：某 B300 节点 8 块 CX8 固件挂死（2026-11）

## 事实

- **环境：** ASRockRack 8U16X-GNR2 B300，固件 40.50.1002，OFED-internal-26.01，内核 6.8.0-100，3 TB 内存，4 个 NUMA 节点（每个约 755 GB）。
- **现象：** 客户反馈"网卡有问题，重启多次，加载 OS 时提示初始化失败"。8 块 CX8 都能枚举，PCIe 链路 Gen6 x16 正常，但都没有绑定驱动，每块卡 `pre-initializing` 120 秒后报 `-110`。

| 时间（北京时间） | 事件 |
|---|---|
| 09-23 ~ 11-01 | 同一固件版本稳定运行 |
| 11-01 17:00 | 业务容器（devpod，entrypoint 是 `sleep infinity`）里同时启动了两个 Mooncake store，`numactl --interleave=0,1` 和 `2,3`，**各自通过 RDMA 注册了 1400 GiB 锁定内存**（日志 `Mounting segment ... 1503238553600 total`，日志时间是 UTC） |
| 17:04 | 两个 store 挂载第 2 段 700 GiB |
| 17:06 | sglang prefill 进程在 `ib_umem_get` 中分配内存失败，触发 OOM（`CONSTRAINT_MEMORY_POLICY,nodemask=0`），杀掉一个 1.18 TiB 的 python3。整机还有约 500 GB page cache |
| 17:08 | 8 块 CX8 在约 1 分钟内先后报 `synd 0x7 irisc not responding`，固件命令全部超时 |
| 17:22 / 21:30 | 两次软重启，都失败。每次开机 CX8 探测超时多花约 16 分钟；openibd 和 Fabric Manager 连带失败 |
| 11-02 13:01 | BMC chassis power off/on，8 块卡约 8 秒内全部初始化成功，800G LinkUp。`mlx5_14/15` 变成了 `mlx5_12/13` |

**根因：** Node0+1、Node2+3 每组约 1406 GiB，两个 store 各注册了 1400 GiB 锁定内存，几乎把各自的节点组占满。sglang 的 TP rank 通过 `numactl --cpunodebind=N --membind=N` 严格绑定在各自的 NUMA 节点上（容器可写层 `/tmp/sglang_temp_file_*.sh` 中可以看到），所以节点一满，这些 rank 申请内存就会直接失败，这正是 `nodemask=0/1` 的来源。容器没有内存上限，`ulimit -l unlimited`，宿主机 `overcommit_memory=1`，所以触发了整机级 OOM。OOM 后固件挂死的具体机制是推断，还没有证实。

## 另一个 agent 为什么没找到根因（对照学习）

那个 agent 读到了 OOM、`CONSTRAINT_MEMORY_POLICY`、1.18 TiB 的进程、`irisc` 的时间线，也查到了 ICMD busy。证据几乎都有，问题出在方法上：

1. **没有往上游追。** 它反复写"OOM 是重要线索，但不能证明因果"，却没有顺着 `cpuset=docker-<id>` 去找容器、`/mnt` 下的脚本和 store 日志。正确做法是：一个进程占 1.18 TiB 是异常值，必须解释它从哪来。
2. **没有说清楚恢复的前提。** "重启多次没好"加上 `pre-initializing`，就应该判断为软重启无法恢复固件、需要冷断电。用户要求"不要重启"时，它应该明确指出这个限制挡住了修复，而不是去研究在线重新加载固件、导出 73 万条寄存器。
3. **把症状当成了故障。** 它把 Fabric Manager 失败、openibd 报 `mlx5_core in use`、`mlx5_ib` 没加载当成了第二条故障线，还修改了 `/etc/init.d/openibd`。这些都是 CX8 卡住 16 分钟带来的连带反应。
4. **被用户的问题牵着走。** 用户问内核版本、问 Fabric Manager，它就逐个去查，排查主线一再被打断。
5. **把时间花在了交付物上。** 反复打包 zip、生成 manifest 和校验值，而真正关键的那一步（看业务配置）一直没做。

本 skill 的作者自己也犯过错：一开始把 OOM 写成"主机内存被占满"（没有按 NUMA 节点核对容量），也只追到"sglang 容器"这一层就停了。这说明"算账"和"追到配置层面"需要明确写进排查流程，而不能指望临场想起来。
