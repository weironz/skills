# 拓扑、性能、温度

## `nvidia-smi topo -m` 少了 NIC

正常的 B300 上，NIC Legend 里能看到全部 CX8（另外还有 BF3 和 CX7 bridge），每块 GPU 都有一块和它是 `PXB` 关系的 NIC。如果少了 NIC，按层回到前面的文档排查：
- 先看 `lspci` 里有没有，再看驱动是否绑定、IB 设备是否存在。
- 大多数情况是第 2 层（固件或驱动初始化）的问题，不是拓扑本身的问题。

## 带宽达不到 800G

1. ATS：`mlxconfig -d /dev/mst/mt4131_pciconfN q | grep ATS_ENABLED`。值为 False 时，需要设置 `ATS_ENABLED=1` 并重启。
2. ACS：GPUDirect RDMA 需要关闭 P2P 路径上的 ACS（厂商提供的 `acs-disable.sh` 脚本，重启后会失效，需要持久化）。
3. 测试：
   ```bash
   ib_write_bw --ib-dev=mlx5_X --duration=5 --qp=4 -b --report_gbits --use_cuda=<同 PXB 的 GPU> --use_cuda_dmabuf [peer]
   ```
   GPU 和 NIC 要选 `PXB` 关系的一对，否则测的是跨 NUMA 的路径。
4. NCCL：`NCCL_IB_HCA` 要和当前的设备名一致（设备名可能变化），8 块网卡不要做 bond。

## 温度

```bash
mget_temp -d /dev/mst/mt4131_pciconfN                                       # 网卡芯片温度
mlxlink -d /dev/mst/mt4131_pciconfN -m | grep -E "Temperature|Rx Power|Tx Power"   # 光模块温度和光功率
```

光模块温度接近阈值上限（例如 `79 [-10..80]`）时，检查风道、风扇策略和机柜进风温度，同时结合 BMC 温度传感器和风扇日志判断。
