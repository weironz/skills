---
name: b300-cx8-troubleshooting
description: >-
  排查 NVIDIA B300/HGX 服务器上 ConnectX-8（CX8，mlx5，PCI ID 15b3:1023）网卡异常的通用方法论与命令集。只要用户反馈 B300/GB300/HGX GPU 节点的 CX8/IB/RDMA 网卡有问题，就使用本 skill，即使用户没有说出"CX8"：例如"网卡初始化失败""mlx5_core probe failed -110""Waiting for FW pre-initializing""irisc not responding""IB 口 down/Polling""ibstat 少了几张卡""/sys/class/infiniband 是空的""Fabric Manager 起不来，No devices found in /sys/class/infiniband""nvidia-smi topo 里 NIC 不见了""800G 降速""重启多次网卡还是不好""NCCL 报 IB 错误"等。也适用于同代 ConnectX-7/BF3 的 mlx5 故障。Troubleshoot NVIDIA ConnectX-8 / mlx5 NIC failures on B300 GPU servers: firmware hang, driver init timeout, PCIe enumeration loss, IB port down, missing RDMA devices, and post-incident root-cause analysis.
---

# B300 CX8 网卡故障排查

本 skill 来自真实故障的复盘（见 `references/case-fw-hang-oom.md`）。那次故障中，另一个 agent 收集到了几乎全部关键证据，却始终没找到根因。原因不在于缺命令，而在于排查方法：没有往上游追触发源、把下游症状当成独立故障，也不知道"软重启不会让 CX8 断电"。所以下面先讲方法，命令放在后面。

## 核心原则

1. **先找出最低一层出故障的地方，它上面的异常都是连带症状。** B300 上 CX8 的依赖链是：
   `PCIe 枚举 → mlx5_core 绑定和固件初始化 → RDMA 设备（/sys/class/infiniband）→ 端口物理层 → IB 逻辑层（SM/LID）→ 业务（NCCL、Fabric Manager、存储）`。
   Fabric Manager 报 `No devices found in /sys/class/infiniband`、openibd 报 `Module mlx5_core is in use`、`mlx5_ib` 没加载、NCCL 报错，常常都是更底层故障的连带反应。最低那层没恢复之前，不要把它们当成独立的根因去修，更不要为此改生产配置或脚本。

2. **找到 T0，并且到 T0 所在的那次启动里去找。** T0 是第一次出现异常的时间。客户说"重启了多次"，就说明当前启动里看到的只是后果。用 `journalctl --list-boots` 找到最后一次正常的启动，在那次启动里定位第一条异常日志。注意每重启一次 boot 编号都会往后错一位，引用时最好写 boot ID；另外注意日志时区（应用日志常用 UTC，内核日志用本地时间）。

3. **找到 T0 之前发生了什么，一直追到配置层面。** 如果 T0 前有 OOM、AER、温度、供电、软件包变更、业务启动等事件，就沿着证据链往上追：
   `OOM 日志中的 cpuset/task_memcg → 容器 → 容器配置和挂载 → 启动脚本 → 业务日志里的实际参数（大小、数量、绑定的 NUMA 节点）`。
   不要停在"时间先后不能证明因果"。这句话只能当作下一步要验证的假设，不能当结论。验证方法是**算账**：比如锁定内存量和 NUMA 节点容量对比、出问题的卡数和共享资源的对应关系。

4. **8 张卡一起坏，先找共同原因。** 同时（几分钟内）出问题、症状相同的多张卡，几乎不会是各自的硬件同时坏了。优先怀疑共同因素：主机内存、驱动、固件缺陷、供电、BIOS、业务负载。只坏几张卡时，看它们有没有共同点（同一个 NUMA 节点、同一台交换机、同一批线缆）；坏的只有一张，再按单卡或物理层处理。

5. **弄清每种恢复手段实际会重置什么。** CX8 走待机电源，**OS 软重启（warm reboot）不会重置挂死的固件**，必须冷断电（BMC chassis power off ≥60 秒，必要时做 AC 断电）。如果"重启多次都没好"，再加上固件初始化超时，基本就可以判断需要冷断电。用户设的限制（比如"不要重启"）如果挡住了唯一的修复办法，要**直接说明**："在这个限制下 CX8 无法恢复，需要安排维护窗口冷断电。"不要在限制内反复绕。

6. **先只读，变更前先说明影响并征得同意。** B300 上有几个常见的连带影响：
   - BF3 管理网的 bond 也由 `mlx5_core` 驱动，重载 `mlx5_core` 可能断开 SSH。
   - CX8 内置 PCIe 交换芯片，GPU 挂在它下面，复位 PCIe 或芯片可能波及 GPU 和 GPU Fabric。
   - `mlxfwreset` 在这个平台上的默认级别可能是整机热重启。
   - 改 `mlxconfig` 后需要重启才生效。

7. **结论要用数字核对，并且区分"已证实"和"推断"。** 例如"内存耗尽"要先核对整机和每个 NUMA 节点的容量（3 TB 的机器发生的可能只是单个节点耗尽）；"降速"要核对协商速率而不是 sysfs 里的默认值（端口 Down 时 rate 显示 10G 是默认值，不代表真的协商成了 10G）。

8. **长期记录用 PCI 地址和 GUID，不要用 mlx5_N。** `mlx5_N` 是按枚举顺序分配的，冷启动后可能变（比如 `mlx5_14/15` 变成 `mlx5_12/13`）。长期记录用 PCI BDF，交换机/UFM 侧用 Port GUID，现场认口用光模块 SN。恢复后要核对业务配置里写死的 `NCCL_IB_HCA` 这类设备名。

## 排查流程

### 第 1 步：建立事实（只读）

先确认机器和登录方式（资产系统、密码库），然后一次性采集现状：

```bash
# 把脚本内容通过 stdin 传给远端执行，不需要先上传文件
ssh root@<host> 'bash -s' < scripts/cx8_snapshot.sh
```

脚本会输出：每块 CX8 的 PCI 地址、驱动绑定、PCIe 链路、IB 设备名和端口状态；本次和上一次启动的 mlx5 关键日志；启动历史；OOM 和页分配失败；每个 NUMA 节点的内存；GPU 数量；最后给出**按层的初步分类**。没有脚本时，手动执行 `references/commands.md` 里的命令也可以。

### 第 2 步：判断最低故障层，按对应文档处理

| 现象（看最低一层） | 归类 | 继续看 |
|---|---|---|
| `lspci -d 15b3:1023` 少于预期，或 GPU 也一起消失 | PCIe 枚举 / 平台故障 | `references/pcie-enumeration.md` |
| 能枚举但**没有绑定驱动**，日志有 `pre-initializing` / `-110` / `irisc not responding` / 命令超时 | **固件挂死 / 驱动初始化失败** | `references/firmware-hang.md` |
| 驱动已绑定，但没有 IB 设备 | RDMA 栈（`mlx5_ib`、openibd、模块版本） | `references/firmware-hang.md` 中"RDMA 栈"一节 |
| IB 设备在，端口 `DOWN`，物理状态是 `Polling`/`Disabled` | 物理链路、光模块、对端交换机 | `references/port-down.md` |
| `LinkUp` 但 State 是 `Down`/`Init` | IB 逻辑层（SM、pkey） | `references/port-down.md` |
| 端口 Active，但速率低、topo 里少了 NIC、带宽不达标、温度高 | 拓扑、性能、热 | `references/topology-perf.md` |

### 第 3 步：找 T0 和触发源

按核心原则 2、3 执行。发现 OOM 时运行：

```bash
ssh root@<host> 'bash -s -- <boot编号>' < scripts/oom_trace.sh
```

它会提取故障所在启动里的 OOM 约束类型、被杀进程、RSS 最大的进程、对应的 cgroup 和容器，以及容器的资源限制（环境变量里的密钥会被打码）。然后顺着容器的挂载和启动脚本，找出实际生效的大小参数，再和 NUMA 容量对比。

### 第 4 步：恢复，必须征得用户同意

按对应 reference 里的恢复步骤执行。动手前要说清楚三件事：这个操作会重置什么、会影响什么（GPU、管理网、业务）、失败了下一步怎么办。

### 第 5 步：验证和收尾

```bash
ssh root@<host> 'bash -s' < scripts/cx8_snapshot.sh   # 再采集一次，和第 1 步对比
```

通过标准：每块 CX8 都显示 `drv=mlx5_core`、`ACTIVE`、`LinkUp`、`800 Gb/sec`；日志里没有 `pre-initializing`、`-110`、`irisc`；GPU 数量正确；需要时还要确认 Fabric Manager 正常、8 张 GPU 的 Fabric 状态为 Completed。然后核对业务配置里的设备名，并落实消除诱因的措施，再恢复业务。

排查过程中如果在远端临时打开了网络路由、取过凭据、留下了临时文件，结束后都要清理，并在报告里写明。

## 报告格式

对用户的结论按下面的结构写，先给结论，篇幅尽量短：

```markdown
## 结论
<一两句话：最低故障层 + 直接原因 + 触发原因 + 当前状态>

## 时间线（注明时区）
| 时间 | 事件 | 依据（日志/命令） |

## 根因链
1. ……（已证实：<证据>）
2. ……（推断：<依据>，还需要 <什么> 才能证实）

## 恢复方案
<步骤、影响范围、需要谁批准>

## 验证结果 / 验证方法

## 规避措施
<必须做（恢复业务前）/ 建议做>
```

如果用户还要求写文档或 SOP，再把命令和关键输出补进去。证据打包（zip、manifest、校验值）留到最后再做，而且只在要提交给厂家时做。不要为了打包耽误排查本身。

## 反模式速查

下面这些都是真实发生过的：

- 发现 OOM 后只写一句"不足以证明因果"，就转去查别的，没有追是谁、用了多少、为什么。
- 记下了"被杀的进程占 1.18 TiB 内存"，却没有追问"一个进程为什么会占这么多"。
- 把 Fabric Manager 和 openibd 的失败当成独立故障，在根因没恢复前就修改了 `/etc/init.d/openibd`。
- 用户要求"不要重启"，就在这个限制内反复想办法（研究在线重新加载固件、导出 73 万条寄存器），没有明确说明需要冷断电。
- 只要用户问到某个方向（内核版本、Fabric Manager），就跟着去查，排查主线被打断。
- 把"主机内存 3 TB"写成"主机内存被占满"，没有按 NUMA 节点核对容量。
- 在当前启动里找最初的故障原因，或者重启后还沿用旧的 boot 编号。

## 参考文件

- `references/commands.md`：按层分类的只读命令清单，没有脚本时使用
- `references/firmware-hang.md`：固件挂死和 RDMA 栈问题的特征、根因追踪、冷断电恢复和验证
- `references/pcie-enumeration.md`：PCIe 未枚举、链路降级、AER、MODS
- `references/port-down.md`：IB 端口 Down 的分诊（ibstat、mlxlink、UFM/GUID）
- `references/topology-perf.md`：topo 丢 NIC、ATS/ACS、带宽测试、温度
- `references/case-fw-hang-oom.md`：完整案例复盘，以及另一个 agent 失败原因的对照分析
- `scripts/cx8_snapshot.sh`：只读的现状采集和按层分类
- `scripts/oom_trace.sh`：只读，从 OOM 追到容器和配置
