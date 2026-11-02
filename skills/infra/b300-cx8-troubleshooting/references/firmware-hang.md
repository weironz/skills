# 固件挂死、驱动初始化失败、RDMA 栈问题

## 1. 特征

| 阶段 | 典型日志 |
|---|---|
| 运行中刚挂死 | `Health issue observed, irisc not responding, severity(3) ERROR`、`synd 0x7: irisc not responding`、`device's health compromised - reached miss count`、`DESTROY_MKEY/ALLOC_UAR/MANAGE_PAGES/CREATE_UCTX ... timeout. Will cause a leak of a command resource` |
| 挂死后再开机 | `wait_fw_init: Waiting for FW pre-initializing, timeout abort in 100s (0x83020000)` → `Firmware over 120000 MS in pre-initializing state, aborting` → `mlx5_init_one failed with error code -110` |
| MFT 查询 | `flint -d <BDF> q` 报 `MFE_CMDIF_TIMEOUT_ERR`；`mlxfwreset -d <BDF> q` 报 `ICMD interface busy with prior request (522)` |
| sysfs | 能枚举，`current_link_speed` 正常（64 GT/s x16），但 `driver` 为空，`infiniband/` 不存在 |

几个细节：
- 每块卡要等 120 秒才超时，8 块卡串行探测，每次开机就要多花约 16 分钟。
- 这段时间里 `mlx5_core` 一直被占用，所以 openibd 会报 `Module mlx5_core is in use`。
- `/sys/class/infiniband` 下没有设备，Fabric Manager 就会报 `No devices found ... within 60 seconds`。

这些都是连带症状，不是独立的故障。

## 2. 根因追踪

1. **定位 T0：** 在保留下来的各次启动里，找第一次出现 `irisc not responding` 的那次启动和时间（`cx8_snapshot.sh` 中的 FIRST HEALTH EVENT 一节）。
2. **查 T0 前 10 分钟的内核日志：**
   ```bash
   journalctl -k -b <B> --no-pager --since "<T0-10min>" --until "<T0+2min>" \
     | grep -E "oom-kill|Out of memory|page allocation failure|AER|NVRM|Xid|mlx5|thermal|power" | cut -c1-300
   ```
3. **按触发源分支：**
   - **OOM 或页分配失败：** 运行 `oom_trace.sh <B>`，追到容器、启动脚本和实际参数，然后算账。已知的一个高风险模式：Mooncake store、hicache 等通过 RDMA 注册了大量锁定内存（`ibv_reg_mr` / `ib_umem_get`），配合 `numactl --interleave/--membind` 把某个 NUMA 节点组占满，引发 `CONSTRAINT_MEMORY_POLICY` 局部 OOM。锁定内存不能换出也不能回收，`ulimit -l unlimited`、`IPC_LOCK`、`overcommit_memory=1` 会让这种超量申请一路畅通。
   - **AER 或 PCIe 错误：** 转到 `pcie-enumeration.md`。
   - **温度或供电：** 查 BMC SEL、`mget_temp`、PSU 事件。
   - **软件变更**（OFED、MFT、固件、内核）：查 `dpkg.log`、`flint q` 的固件版本、`last -x`。注意要确认是"已安装"还是"已经用新版本启动过"。
   - **什么都没找到：** 收集证据（见第 5 节），提交给 NVIDIA。
4. **判断是否共模故障：** 统计几块卡挂死、间隔多久、`synd/ext_synd/irisc_index` 是否相同。多块卡在几分钟内先后挂死，说明有共同触发因素，不要按换卡处理。
5. **对照正常节点：** 同型号、同版本的正常节点可以帮助排除固件和驱动版本问题。但如果故障节点在同一版本上长期正常运行过，版本问题基本可以直接排除。

要说清楚证据的边界：OOM 导致 iRISC 挂死的**具体机制**，单靠内核日志通常无法证实，需要厂家分析 FW dump。报告里要写成"推断"。

## 3. 恢复

| 手段 | 是否能重置挂死的固件 | 影响 |
|---|---|---|
| `reboot`（软重启） | **不能**（CX8 走待机电源） | 浪费时间，每次开机多花约 16 分钟 |
| 重载 `mlx5_core` | 不能（固件命令通道仍然 busy） | 会断开 BF3 管理网（SSH） |
| `mlxfwreset` | ICMD busy 时通常无法执行；默认级别可能是整机热重启 | 可能波及 GPU |
| **BMC chassis power off ≥60s → on** | **能**（真实案例已验证） | 整机断电，GPU 业务中断 |
| AC 断电 2～3 分钟 | 能（冷断电无效时再用） | 需要现场人员 |

```bash
ipmitool -I lanplus -H <BMC> -U <user> -P <pass> chassis power off
sleep 90
ipmitool -I lanplus -H <BMC> -U <user> -P <pass> chassis power status   # 确认是 off
ipmitool -I lanplus -H <BMC> -U <user> -P <pass> chassis power on
```

**冷断电之前，先把证据留好：** 当前启动和故障所在启动的内核日志、`lspci -tv`、业务脚本和业务日志。断电后 boot 编号会再往后错一位。

## 4. 验证

再执行一次 `cx8_snapshot.sh`。通过标准：
- 每块卡都显示 `drv=mlx5_core`、`ACTIVE`、`LinkUp`、`800 Gb/sec (4X XDR)`。
- 内核日志里每块卡都打印了 `Rate limit: 127 rates are supported`（表示初始化成功）。
- 没有 `pre-initializing`、`-110`、`irisc`。
- GPU 数量正确，Fabric Manager 为 active，GPU Fabric 状态为 Completed。

然后核对 `mlx5_N` 设备名有没有变化，以及业务配置里写死的 `NCCL_IB_HCA`、`MOONCAKE_DEVICE`、`--disaggregation-ib-device` 等。

**恢复业务前要消除诱因：**
- 按单个 NUMA 节点容量规划锁定内存：`segment + host pool + 加载峰值 + 15%～20% 预留 ≤ 节点组容量`，全机锁定内存不超过 60%。
- 多个大 segment 不要同时挂载。
- 容器设置 `--memory`，`ulimit -l` 设上限，生产环境不要用 `--privileged`。
- `vm.min_free_kbytes` 调到 2～4 GB。
- 按 NUMA 节点监控 MemFree。

## 5. 提交厂家的证据

```bash
mkdir -p /root/cx8-hang-$(date +%F) && cd $_
journalctl -k -b <B> --no-pager > kernel-boot<B>.log; journalctl -k -b --no-pager > kernel-current.log
lspci -tv > lspci-tv.txt; lspci -Dnnvvv -d 15b3: > lspci-vvv-mlx.txt
ofed_info -s > ofed.txt; mst version > mft.txt; numactl -H > numa.txt
# 可选：mstdump <BDF> > mstdump-<BDF>.dmp（只读，但耗时较长；挂死时导出的寄存器对厂家分析有价值）
```

同时附上：固件版本、每块卡的 `synd`/`ext_synd`/`irisc_index`/`assert_var`、T0 前后的时间线、业务内存配置。

## 6. RDMA 栈（驱动已绑定但没有 IB 设备）

- `lsmod | grep mlx5_ib`；`modinfo mlx5_ib | grep -E 'vermagic|srcversion'` 要和 `/sys/module/mlx5_core/srcversion` 一致。
- `systemctl status openibd`、`journalctl -u openibd -b`。DOCA 3.3 的 `/etc/init.d/openibd` 有一个参数转发缺陷（`global_init "$1"` 应为 `"$@"`，NVIDIA Bug 4850615，DOCA 3.4.0 修复）。
- **先确认 CX8 本身已经正常**（驱动已绑定、没有探测超时），再判断 openibd 是不是独立的问题。CX8 探测卡住 16 分钟时，openibd 失败是预期中的连带现象。
- `modprobe mlx5_ib` 可以在不重载 `mlx5_core` 的情况下让 CX7 bridge 和 BF3 的 RDMA 设备出现，进而让 Fabric Manager 恢复，属于临时缓解。执行前要征得用户同意，而且它修复不了 CX8 的固件挂死。
