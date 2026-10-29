# WiFi STA + iperf 吞吐测试固件（reSpeaker Clip）

STA 模式 WiFi 吞吐测试：设备以 station 身份连接现有路由器，通过 DHCP 获取地址，
对同网段主机发起 iperf2 兼容的 UDP 打流（zperf）。
基于验证过的 `samples/wifi_ap_iperf`（AP 样例）最小改动移植，仅把 AP 启停换成
STA 连接 + DHCP 客户端，其余（开机自动起 RPU、扫描、zperf、shell）保持一致。

## 构建与烧录

```sh
source ~/ncs/v3.3.0/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)   # 仓库根目录

west build --build-dir build-wifi-sta --board clip/nrf5340/cpuapp \
    --pristine=always samples/wifi_sta_iperf
```

烧录（J-Link 直刷完整镜像，含 MCUboot + netcore；**整片覆盖，会替换生产固件**）：

```sh
nrfutil device program --firmware build-wifi-sta/merged.hex --serial-number <SN>
nrfutil device reset --serial-number <SN>
```

恢复产线固件：用 `output/0.1.5/clip-0.1.5-*-merged.hex` 同样方式重烧。

串口：UART0 调试串口，**921600**。

## 命令

```
wifi connect <SSID> <密码> [band]   # 连接 WPA2-PSK 并等 DHCP；band: 0=自动(默认) 1=2.4G 2=5G
wifi disconnect                     # 断开
wifi scan [band]                    # 扫描：信道/SSID/RSSI/频段
wifi status                         # 连接状态 + IP
iperf <PC的IP> [时长秒] [速率kbps]  # UDP 打流；时长最长 86400（24小时）
```

示例：

```
wifi connect MyRouter mypassword 1
iperf 192.168.199.30 86400          # 连续跑 24 小时
```

## 每 5 秒进度报告

zperf 本身只在会话结束时汇报一次；固件额外**每 5 秒**打印接口 TX 统计：

```
[iperf] t=5096ms tx=2676KB rate=4280 kbps
```

结束时的最终报告：

```
[iperf] pkts=xxxx lost=x bytes=xxxxxxxx time=60000ms
[iperf] Throughput: xxxx kbps (xx.xxx Mbps)
```

**注意**：iperf 运行期间 shell 被占用（Ctrl+C 无法中断），中途停止需按复位。

## PC 端（iperf2，不是 iperf3）

zperf 说的是 **iperf v2** 的 UDP 协议；iperf3 不兼容（服务端认不出数据包，表现为无显示）。

```
iperf -v          # 必须是 2.x
iperf -s -u -p 5001 -i 1
```

Windows 防火墙需放行入站 UDP 5001（管理员 PowerShell）：

```powershell
netsh advfirewall firewall add rule name="iperf2-udp" dir=in action=allow protocol=UDP localport=5001
```

## 排障

| 现象 | 结论 | 处理 |
|------|------|------|
| 设备 5 秒报告 `rate>0`，PC 端无显示 | 设备在发，路径断 | PC 防火墙放行；确认 iperf 是 2.x；确认填的是 PC 在该路由器子网的 IP（`ipconfig`） |
| 设备 `rate=0`、tx 不涨 | 设备没发出去 | `wifi status` 确认已连接有 IP；检查路由器 AP 隔离/客户端隔离设置 |
| 连接超时 | 路由器拒绝 | 确认 WPA2-PSK（不支持开放网络/WPA3）；5G 需信道在频域允许范围内 |
| PC 显示 connected 但无后续统计 | 正常 | iperf2 UDP 服务端结束才出汇总；`-i 1` 每秒一行 |

## 限制

- 仅 WPA2-PSK；SSID/密码为命令行参数，不持久化
- 仅 UDP 上行（设备 → PC）
- 镜像不含电池监控，USB 供电运行
