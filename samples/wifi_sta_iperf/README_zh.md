# reSpeaker Clip WiFi STA 吞吐测试固件 — 使用说明

| 项 | 值 |
|----|-----|
| 用途 | 设备以 STA（station）模式连接现有路由器，对局域网主机发起 UDP 打流，测试 WiFi 吞吐 |
| 固件形态 | 独立测试镜像（MCUboot + 应用 + 网络核），**非量产固件**，测试完需重刷产线固件 |
| 构建来源 | `samples/wifi_sta_iperf` @ commit `0fab71d`（分支 release/0.1.5） |
| 产物 | `clip-wifi-sta-iperf-merged.hex`（烧这个）、`signed_by_mcuboot_and_b0_ipc_radio.hex`（备用） |
| 已上板验证 | 连接/扫描/iperf 单次与长时间打流（Windows iperf2 服务端实测通过） |

---

## 1. 烧录

J-Link 直刷完整镜像（整片覆盖，会替换量产固件）：

```sh
nrfutil device program --firmware clip-wifi-sta-iperf-merged.hex --serial-number <SN>
nrfutil device reset --serial-number <SN>
```

测试完成后恢复产线固件：用 `output/0.1.5/clip-0.1.5-production-merged.hex` 同样方式重烧。

## 2. 连接与命令

串口：板载 USB 单串口（PID `2886:0069`），**921600**，任意串口终端。
开机横幅会打印构建时间（确认烧录是否成功）。

| 命令 | 说明 |
|------|------|
| `wifi scan [band]` | 扫描：信道/SSID/RSSI/频段（band: 0=全部 1=2.4G 2=5G） |
| `wifi connect <SSID> <密码> [band]` | 连接 WPA2-PSK 并等 DHCP，成功打印 IP |
| `wifi status` | 连接状态 + IP |
| `wifi disconnect` | 断开 |
| `iperf <PC的IP> [时长秒] [速率kbps]` | UDP 打流；时长最长 86400（24 小时）；速率默认 100000 |

示例（连 2.4G、打流 24 小时）：

```
wifi connect MyRouter mypassword 1
iperf 192.168.199.30 86400
```

## 3. 每 5 秒进度报告

zperf 本身只在结束时汇报；固件额外每 5 秒打印接口 TX 统计：

```
[iperf] t=5096ms tx=2676KB rate=4280 kbps
```

结束时打印最终报告（包数/丢包/吞吐）。**注意**：iperf 运行期间 shell 被占用，
中途停止需按设备复位键。

## 4. PC 端（iperf v2，不是 iperf3）

zperf 说的是 **iperf v2** 的 UDP 协议；**iperf3 不兼容**（服务端认不出数据包，
表现为无任何显示——不是固件问题）。

```
iperf -v          # 必须显示 2.x
iperf -s -u -p 5001 -i 1
```

Windows 防火墙放行入站 UDP 5001（管理员 PowerShell）：

```powershell
netsh advfirewall firewall add rule name="iperf2-udp" dir=in action=allow protocol=UDP localport=5001
```

**结果判读**：
- 设备 5 秒报告 `rate>0` 且 PC 端无显示 → 查 PC：iperf 版本、防火墙、IP 是否
  填了 PC 在该路由器子网的地址（`ipconfig` 确认）
- 设备 `rate=0` 且 tx 不涨 → 查设备：`wifi status` 是否连接有 IP、路由器是否
  开了 AP 隔离

## 5. 限制

- 仅 WPA2-PSK（不支持开放网络/WPA3）；SSID/密码为命令行参数，不持久化
- 仅 UDP 上行（设备 → PC）
- 镜像不含电池监控，请 USB 供电运行
- 5G 频段取决于路由器信道（频域 US）

## 6. 从源码构建（可选）

```sh
source ~/ncs/v3.3.0/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=<仓库根目录>

west build --build-dir build-wifi-sta --board clip/nrf5340/cpuapp \
    --pristine=always samples/wifi_sta_iperf
```

源码与英文版说明：`samples/wifi_sta_iperf/`（README_zh.md 为同内容文档）。
