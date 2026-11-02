# PCIe 未枚举、链路降级、AER

## 判断

```bash
lspci -Dnn -d 15b3:1023 | wc -l                  # B300 预期 8 块
lspci -Dnn | grep -ci nvidia                     # GPU 是否也缺
lspci -tv                                        # 看缺失的设备挂在哪个根端口或交换芯片下
for d in $(lspci -D -d 15b3:1023 | awk '{print $1}'); do
  echo "$d $(cat /sys/bus/pci/devices/$d/current_link_speed) x$(cat /sys/bus/pci/devices/$d/current_link_width) (max $(cat /sys/bus/pci/devices/$d/max_link_speed) x$(cat /sys/bus/pci/devices/$d/max_link_width))"
done
journalctl -k -b --no-pager | grep -iE "AER|pcieport|DPC|link down|Surprise|bus error" | head -40
```

**B300 拓扑要点：**
- CX8 内置 PCIe 交换芯片（`15b3:197c`），GPU 挂在它下面（`nvidia-smi topo -m` 中 GPU 和 NIC 的关系是 `PXB`）。
- 内核日志里出现 `limited by 32.0 GT/s ... at <根端口>` 是正常的：CPU 根端口是 Gen5，CX8 到 GPU 一侧是 Gen6。

| 现象 | 指向 |
|---|---|
| GPU 和多块 CX8 一起从 `lspci` 消失 | 共享的上游路径：CPU 根端口、基板、riser、MCIO 线缆、供电、BIOS 链路训练 |
| 单块 CX8 消失 | 该槽位、线缆、卡本身 |
| 枚举到了但链路宽度或速率低于预期 | 信号完整性、retimer、线缆，持续增长的 AER correctable 计数是佐证 |

## 处理

1. 处理前先留证据：`lspci -tv`、`lspci -vvv`、内核日志、BMC SEL 和 POST 日志、`last -x`，以及最近有没有拆机、换卡、改 BIOS。
2. 先做一次完整冷断电，再比较前后的枚举结果。
3. 冷断电后仍然缺失：按整机厂商的流程检查基板、riser、MCIO、根端口和供电，必要时对调模块交叉验证。另一个案例就是用 MODS 测试定位到某块 GPU 模块的 PCIe correctable/NAK 超阈值，对调模块后恢复正常。
4. 设备完全不在 `lspci` 里时，重装驱动、重启 Fabric Manager、复位交换机端口都没有意义。
