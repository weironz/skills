# 按层分类的只读命令清单（没有脚本时使用）

| 层 | 命令 |
|---|---|
| 启动历史 | `journalctl --list-boots --no-pager \| tail`；`last -x reboot shutdown \| head` |
| L1 PCIe | `lspci -Dnn -d 15b3:1023`；`lspci -tv`；`/sys/bus/pci/devices/<BDF>/{current_link_speed,current_link_width,numa_node}` |
| L2 驱动/固件 | `readlink /sys/bus/pci/devices/<BDF>/driver`；`journalctl -k -b <B> \| grep mlx5_core`；`flint -d <BDF> q`（限 20s）；`mlxfwreset -d <BDF> q`（只是查询） |
| L3 RDMA | `ls /sys/class/infiniband`；`lsmod \| grep mlx5`；`systemctl status openibd`；`rdma link show` |
| L4 端口 | `ibstat`；`/sys/class/infiniband/<ib>/ports/1/{state,phys_state,rate}`；`mlxlink -d <BDF> -m -c -e` |
| L5 IB 逻辑 | `sminfo`；`iblinkinfo`；UFM event.log（按 GUID 检索） |
| 上层 | `nvidia-smi -L`；`nvidia-smi -q \| grep -A2 Fabric`；`systemctl status nvidia-fabricmanager`；`nvidia-smi topo -m` |
| 触发源 | `journalctl -k -b <B> \| grep -E "oom-kill\|page allocation failure\|AER\|NVRM\|Xid"`；`grep -E " (install\|upgrade) " /var/log/dpkg.log`；`numactl -H`；`docker ps -a --no-trunc` |
| 版本 | `ofed_info -s`；`mst version`；`uname -r`；`modinfo mlx5_core \| grep -E "^version\|filename"` |

**不是只读、需要用户同意才能执行的操作：**
`modprobe`/`rmmod`、`systemctl start/restart`、`mlxfwreset reset`、`mlxconfig set`、`mlxlink --link_reset`、`flint burn`、`reboot`、BMC 电源操作，以及修改 `/etc` 下的任何文件。
