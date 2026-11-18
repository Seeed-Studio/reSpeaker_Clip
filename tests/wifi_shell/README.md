# Wi-Fi Shell 认证测试固件（tests/wifi_shell）

Nordic NCS `nrf/samples/wifi/shell`（+ zperf overlay）在 reSpeaker Clip 上的移植。
这是 Nordic 官方 adaptivity 认证文档指定的 DUT 固件形态（STA 连接实验室 AP +
zperf UDP 上行 + `nrf70 util tx_rate` 固定发射速率）：

> nrf/doc/nrf/protocols/wifi/regulatory_certification/adaptivity_test_procedure.rst
> （中文译本：output/adaptivity_test_procedure.zh-CN.md）

配置原则：驱动/射频层与量产固件对齐（coex 关闭——单无线电视频测试无需 coex；
WPA2-PSK only；NEWLIB；2.4G 发射功率上限 9 dBm / 5G 6 dBm 由板级 DTS
`wifi-max-tx-pwr-*` 下发，所有构建共享），测试层增加 Wi-Fi shell、zperf、
`nrf70 util`。支持 2.4G 和 5G（nRF7002 双频）。

## 固件信息

| 项 | 值 |
|---|---|
| 镜像 | `wifi_shell_clip.hex`（无 MCUboot，**J-Link 直烧**） |
| 烧录 | J-Link 全片擦写（nRF7002DK 的 nrfutil/west flash 均可） |
| 控制台 | UART0 @ **921600**，引脚 P1.05(TX)/P1.04(RX) |
| 功率配置 | 2.4G ≤9 dBm（DSSS/HT）、5G ≤6 dBm（板级 DTS，与量产一致） |
| MAC | 每次开机随机（板子无 OTP MAC；路由器客户端列表会积累旧租约，正常） |

## Adaptivity 重测流程（EN 300 328 / EN 301 893）

按 Nordic 文档，DUT 作为 STA 连接实验室 AP，**固定低速率**保证 >30% 发包占空比：

```sh
# 1. regulatory domain（5G 必须；2.4G 建议也设）
wifi reg_domain -f DE        # CE 用 EU 国家码，按实验室要求

# 2. 连接实验室 AP
#    -k 1 = WPA/WPA2-PSK（本固件只支持 0=Open 和 1=WPA2-PSK，WPA3 已按量产裁掉）
wifi connect -s <SSID> -k 1 -p <passphrase>
wifi connect -s <SSID> -k 1 -p <passphrase> -b 5      # 5G

# 3. 固定发射速率（关键步骤！Nordic 程序原文要求）
nrf70 util tx_rate 0 6       # 0=legacy 组，固定 6 Mbps OFDM（文档推荐值）
#   11b DSSS：1 / 2 / 55(=5.5) / 11        ← 复现实验室原 11B 测试模式
#   HT/VHT/HE：nrf70 util tx_rate 1 0      ← MCS0，≈6.5 Mbps
#   解除固定：nrf70 util tx_rate 0 -1

# 4. 持续 UDP 上行（AP/PC 侧先起 iperf2 服务端）
zperf udp upload <服务器IP> 5001 -1 1k 20M
#   -1 = 无限时长（实验室挂机用；见下方"注意事项"）
#   调试建议用有限秒数，如 30
```

速率固定生效的验证：打流时 `wifi status` 的 `Current PHY TX rate` 与固定值
一致；固定 6 Mbps 时 zperf 实测吞吐 ≈4–5 Mbps。

## PC/服务端要求（iperf）

- **必须 iperf v2**（zperf 只兼容 v2 协议；iperf3 收了包也全丢弃且无提示）
- 参数顺序注意：`-i` 必须带数字，**`-s -u -i 1 -p 5001`**（写成 `-i -u` 会静默
  变成 TCP 服务器）
- Windows 防火墙放行入站 UDP 5001（或临时关闭）
- UDP 无连接概念：服务端只在收到流量后打每秒统计行，启动时没有"连接"提示

## 注意事项（实机踩坑记录）

1. **`zperf ... -1` 会占死 shell**：无限时长下 shell 线程同步等待会话结束，
   永远没有下一行输出、没有提示符——这是设计行为不是死机（设备在正常发射）。
   只有断电/复位能解除。实验室挂机无所谓，调试阶段一律用有限秒数。
2. **zperf 只在会话结束时打印统计**，运行期间设备端无任何输出，进度看 PC 端。
3. **随机 MAC**：每次开机 MAC 变化 → 每次开机拿到新 DHCP 租约，路由器客户端
   列表会越积越多（旧条目会老化），不影响测试。
4. **失败后的 10 秒拉黑**：连接失败后 supplicant 将该 SSID 拉黑 10 秒
   （`SSID-TEMP-DISABLED`），期间重连必失败，等 10 秒。
   "pre-shared key may be incorrect" 多数时候是误导——弱信号导致四次握手
   超时也报这句。
5. **5G 注意**：必须先 `wifi reg_domain -f <国家码>`；板级 5G 功率上限 6 dBm，
   距离路由器远会连不上；若 5G 完全扫不到/连不上需确认产品天线是否为
   双频设计（固件侧无 5G 开关）。
6. 密码含空格要加引号：`-p "my pass"`。

## 常用命令速查

```sh
wifi scan [-b 5]                 # 扫描（2.4G/5G）
wifi status                      # 连接状态 + 当前 PHY 发射速率
wifi statistics                  # 驱动统计（重传等，干扰实验时重点看）
wifi disconnect
wifi reg_domain                  # 查当前国家码
net ip                           # 查设备 IP（DHCP）
net ping <ip>                    # ping（链路排查第一步）
nrf70 util show_config           # 当前固定速率等配置
nrf70 util tx_rate 0 -1          # 解除速率固定
kernel reboot
```

## 与 CE 报告 fail 项的关系（背景）

v0.1.x 送测的 STA 固件（samples/wifi_sta_iperf）在 EN 300 328 adaptivity
AWGN 子项 11B 模式测得 20%（限值 10%）。Nordic 官方测试程序中 DUT 固定的
是 6 Mbps OFDM，不存在 11B 模式；本固件即为按 Nordic 程序重测准备的 DUT
（支持以 `nrf70 util tx_rate 0 1` 复现 11B@1Mbps 模式做对照）。
另请实验室核对：报告 AWGN 电平（-63.86 dBm）按 TL 公式反推约 14 dBm Pout，
而本产品 2.4G 实际发射功率上限为 9 dBm（板级配置）——重测时 TL 取值应与
实测功率一致。

## Build（内部）

```sh
source ~/ncs/v3.3.0/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=/home/lht/clip
west build --build-dir build-wifi-shell --pristine \
    --board clip/nrf5340/cpuapp tests/wifi_shell
west flash --build-dir build-wifi-shell
```

无 MCUboot / 无 netcore（`sysbuild.conf`），J-Link 直烧。认证/工厂固件
不通过 OTA 升级。
