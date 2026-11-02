# IB 端口 Down / 降速

前提：驱动已绑定，`/sys/class/infiniband` 下有设备。端口状态以 `ibstat` 为准，`ibdev2netdev` 显示的是 IPoIB 状态，不能用来判断。

## 分诊

```bash
for d in $(lspci -D -d 15b3:1023 | awk '{print $1}'); do
  ib=$(ls /sys/bus/pci/devices/$d/infiniband 2>/dev/null)
  echo "$d $ib $(cat /sys/class/infiniband/$ib/ports/1/state) $(cat /sys/class/infiniband/$ib/ports/1/phys_state) $(cat /sys/class/infiniband/$ib/ports/1/rate) numa=$(cat /sys/bus/pci/devices/$d/numa_node)"
done
```

端口 Down 时 `rate` 显示 10G 是默认值，并不是真的协商成了 10G。

| Physical state | mlxlink 提示 | 多半原因 | 处理 |
|---|---|---|---|
| Polling | Cable unplugged / Identifier N/A | 空口或线没插好 | 插线或重插 |
| Polling | No signal / remote side | 对端交换机口或线缆另一头 | 查交换机口、UFM |
| Polling | Bad signal / Bad cable，RX 功率低 | 光衰、端面脏、模块坏 | 清洁、换线、换模块 |
| Disabled | Port disabled | 管理性关闭 | 在交换机或 UFM 侧启用，或 `mlxlink --link_reset` |
| LinkUp，但 State Down/Init | — | SM、pkey 配置 | `sminfo`、UFM |
| Active，但 Rate 低于 800 | 速率或宽度不匹配 | 信号或对端配置 | 看 `mlxlink -e` 的 BER 和 FEC |

```bash
mst start
mlxlink -d <BDF 或 /dev/mst/mt4131_pciconfN> -m -c -e | grep -iE \
  "State|Physical|Speed|Width|FEC|Identifier|Cable|Vendor Serial|Power|Temperature|BER|Recommendation|Opcode"
dmesg -T | grep -i "mlx5_core <BDF>" | grep -iE "module|cable|link" | tail
mlxconfig -d <BDF> q | grep -E "LINK_TYPE"      # 应为 IB(1)
```

## 对端和历史

- 端口 Down 后，`ibnetdiscover` 看不到对端，要到 UFM 的历史事件里查。用 Port GUID 跨主机名和交换机端口名追踪：
  ```bash
  ibstat mlx5_N | grep 'Port GUID'
  grep -iE 'Link went down.*<guid>' /opt/ufm/files/log/event.log     # 在 UFM 主机上执行
  ```
- 有多个端口 Down 时，看它们有没有共同点：同一个 NUMA 节点、同一台交换机、同一块板卡、同一批线缆。
- 记录时同时写上 PCI 地址、mlx5 设备名和光模块 SN，交给现场人员时用 SN 认口。

## 经验频率（从高到低）

空口没插线 > 对端交换机口没起来或没配置 > 光模块或线缆故障、没插到位 > 光衰 > SM/pkey 配置 > 管理性关闭
