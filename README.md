# DGX Spark Tools

DGX Spark (GB10 Grace Blackwell) 运维工具集。

## 脚本列表

| 脚本 | 用途 |
|------|------|
| `spark-monitor.sh` | TUI 实时监控面板（GPU/CPU/温度/内存/网络） |
| `spark-netcfg.sh` | 管理口网络配置（静态IP/DHCP切换） |

## 使用方法

```bash
# 监控面板（默认 2 秒刷新）
bash spark-monitor.sh
bash spark-monitor.sh 5  # 5 秒刷新

# 网络配置
bash spark-netcfg.sh show
bash spark-netcfg.sh set 192.168.103.221/24 192.168.103.3 192.168.103.3
bash spark-netcfg.sh dhcp
```

## 部署

```bash
# 从 Mac mini 批量推送到所有 Spark
for h in spark1 spark2 spark3; do
    scp spark-monitor.sh spark-netcfg.sh $h:~/
done
```

## 环境

- NVIDIA DGX Spark (GB10 Grace Blackwell)
- DGX OS (Ubuntu-based)
- 管理口: enP7s7 (2.5GbE)
- QSFP: ConnectX-7 (200GbE x2)
