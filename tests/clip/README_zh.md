# reSpeaker Clip 硬件测试套件

## 概述

此测试套件为基于 nRF5340 的 reSpeaker Clip 板提供全面的硬件组件测试。

## 构建

```bash
# 设置环境（NCS v3.3.0；main 需要 v3.3.0 专属 Kconfig）
source ~/ncs/v3.3.0/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)

# 构建（VERSION/Kconfig/DTS 改动后必须 pristine）
west build --build-dir build-test --pristine always --board clip/nrf5340/cpuapp tests/clip

# 烧录并重置（该镜像不走 MCUboot，直接 J-Link 烧录；
# 本板 west flash --reset 无效，需用 nrfutil 复位）
west flash --build-dir build-test && nrfutil device reset
```

## 串口配置

- **波特率**: 921600
- **端口**: /dev/ttyACM0 (或适当的 USB-串口端口)
- **连接**: `minicom -D /dev/ttyACM0 -b 921600`

## 测试模块

### 设备标识（产测）

每块板的 **BLE 广播名** 与 **WiFi AP SSID** 都带一个取自 chip_id（nRF5340 FICR DEVICEID，出厂固化、重启/重刷不变）的唯一后缀，便于产测在多板同 jig 时按名/RSSI 锁定当前板：

- **BLE 名**: `Clip_<6位hex>`（如 `Clip_A1B2C3`）
- **AP SSID**: `Clip_<6位hex>`（与 BLE 同后缀，如 `Clip_A1B2C3`）

串口命令 `ident` 一次读出当前板的全部标识：

```
uart:~$ ident
BLE name : Clip_A1B2C3
BLE MAC  : AA:BB:CC:DD:EE:FF
AP SSID  : Clip_A1B2C3
suffix   : A1B2C3 (chip_id last 6 hex)
```

> 后缀长度默认 6 位 hex（24 位），可在 `src/identity.c` 的 `IDENTITY_SUFFIX_HEX_LEN` 改为 8/12（FICR 有 16 hex 位足够）。

### 1. BLE 测试

**目的**: 测试作为外围设备的蓝牙低功耗功能

**描述**: BLE 在启动时自动开始广播。连接 BLE 中央设备以测试 GATT 服务和吞吐量。

**命令**:
```bash
ble_txpower <dBm>    # 设置 BLE 发射功率（广播，如有活动连接也一并设置）
```
nRF5340 发射功率档位：`-40, -20, -16, -12, -8, -4, 0, 3, 4, 5, 6, 7, 8` dBm。命令会同时
打印请求值与实际选中的功率（不带参数运行则打印用法/档位列表）。

**预期结果**:
- 设备广播为 `Clip_<6位hex>`（每台唯一，见上方"设备标识"）
- 支持 GATT 连接和通知以进行吞吐量测试

### 2. WiFi AP 测试

**目的**: 测试 nRF7002 WiFi 模块在 AP (热点) 模式下

**AP 配置**:
- SSID: `Clip_<6位hex>`（每台唯一，见上方"设备标识"）
- 密码: `12345678`
- 频段/信道: 可配置 —— `wifi on <channel>`（2.4GHz: 1-13，5GHz: 36-165；默认 36 / 5GHz）
- IP: 192.168.4.1
- DHCP 池: 192.168.4.2+

**命令**:
```bash
wifi on [channel]    # 启动 AP（2.4G:1-13, 5G:36-165；默认 36）
wifi off             # 停止 AP
wifi status          # 显示 AP 状态
wifi scan [band]     # 扫描网络（0=全部, 1=2.4G, 2=5G）
```

**快速测试**:
1. 运行 `wifi on`，注意串口输出中的 SSID
2. 将手机/PC 连接到 `Clip_<6位hex>`（运行 `ident` 读取本板 SSID），密码 `12345678`
3. 设备应通过 DHCP 获取 192.168.4.x 地址
4. 运行 `wifi status` 以确认 AP 正在运行

---

#### WiFi 吞吐量测试 (zperf / iperf2)

**概述**: 设备使用 zperf 进行 UDP 吞吐量测试，与 iperf2 兼容。

**测试类型**: 从设备到 PC 的 UDP 上载 (设备发送，PC 接收)

**默认参数**:
- 服务器 IP: 192.168.4.10
- 端口: 5001
- 时长: 10 秒
- 速率: 100 Mbps (100000 kbps)

**测试步骤**:

**步骤 1: 在 PC 上启动 iperf2 服务器 (连接到 Clip AP)**
```bash
iperf -s -u -p 5001 -i 1
```

**步骤 2: 在设备上运行 iperf 测试**
```bash
iperf                       # 使用默认值 (192.168.4.10, 10s, 100Mbps)
iperf 192.168.4.10          # 指定 PC IP
iperf 192.168.4.10 30       # 30 秒测试
iperf 192.168.4.10 10 50000 # 10 秒测试，速率 50 Mbps
```

**命令参数**:
| 参数 | 描述 | 范围 | 默认值 |
|------|------|------|--------|
| server_ip | PC IP 地址 | 任何有效 IP | 192.168.4.10 |
| duration_sec | 测试时长 | 1-3600 秒 | 10 |
| rate_kbps | 发送速率 | 100-1000000 kbps | 100000 |


---

### 3. SD 卡测试

**目的**: 测试 SD 卡文件系统操作

**命令**:
```bash
sd mount                          # 挂载 SD 卡
sd umount                         # 卸载 SD 卡
sd format                         # 将 SD 卡格式化为 FAT32
sd speed [size_kb]                # 速度测试（写+读）
sd verify [size_kb] [pattern 0-5] # 可靠性验证（写+读+比对，统计不匹配字节）
sd test <rounds> [size_kb]        # 多轮可靠性测试（prbs 伪随机，默认 1MB/轮）
sd patterns [size_kb]             # 全模式扫描
sd status                         # 显示 SD 卡状态
fs ls /SD:                        # 列出文件
```

**可靠性测试**（`sd verify` / `sd test` / `sd patterns`）：每轮写一种模式、读回、比对——不匹配字节计数（不会因此中止）。`sd test <rounds>` 循环 `<rounds>` 轮，逐轮打印一行，结束后打印汇总（总轮数、总字节、总错误、失败轮数）。长时间拷机示例：`sd test 100000` 在 1MB/轮下约跑 5 天（累计写入约 94GB，≈6 次全卡写入，远低于 TLC 耐久度；缓冲区是静态的，5 天无堆增长）。注意：遇到需要重新挂载的持续 I/O 故障时**不会自动 remount**，会一直失败到轮数跑完。

**预期结果**:
- SD 卡在存在时挂载
- 文件列表正常工作
- 卸载安全卸载

### 4. 麦克风测试

**目的**: 测试 PDM 麦克风音频捕获和 WAV 录音

**命令**:
```bash
mic capture [time_sec]  # 捕获音频并打印采样统计
mic record [time_sec]   # 录制 WAV 文件到 SD 卡 (默认 3 秒)
```

麦克风电源（NPM1300 LDO1 1.8V + PDM 电平转换器）在 `capture`/`record` 开始时自动上电，结束后自动断电。

**预期结果**:
- 音频捕获启动和停止
- 每个数据块打印采样统计 (avg/min/max)
- WAV 文件保存到 SD 卡 (RECXXXX.WAV)

**典型工作流**:
1. 插入 SD 卡并挂载: `sd mount`
2. 录制音频: `mic record 5`
3. 启用 USB MSC 访问文件: `usb msc on`
4. 在电脑上从 USB 驱动器复制 WAV 文件
5. 禁用 USB MSC: `usb msc off`

### 5. 按钮测试

**目的**: 测试用户按钮功能

**预期结果**:
- 检测到按钮按下并记录日志

### 6. OLED 显示测试

**目的**: 测试 CH1115 OLED 显示 (88x48)

**命令**:
```bash
oled test            # 运行自动化测试
oled clear           # 清除显示
oled fill            # 填充显示
oled pattern         # 显示测试图案
oled circle          # 绘制圆圈
oled pixels          # 绘制测试像素
oled brightness <0-255>  # 设置亮度
```

**预期结果**:
- 显示正确显示测试图案
- 亮度调整工作
- 无可见瑕疵
- 除主动执行 OLED 测试命令外，屏幕始终显示电量百分比、电压、充/放电状态和 NTC 温度（每秒刷新）

### 7. PMIC 测试

**目的**: 测试 NPM1300 PMIC 电池和电源管理

**命令**:
```bash
pmic status          # 显示电池/充电器状态
pmic monitor [count] # 每秒输出一次滤波后的状态（默认 10 次）
pmic ship            # 保存电量计状态后进入船模式（关机）
```

**预期结果**:
- OLED 始终显示经滤波的电量百分比、电压、充/放电状态和温度
- 电量使用与正式固件一致的基于模型的 nRF Fuel Gauge
- 电量计状态在显示百分比改变时、以及重启/SYSTEM OFF/ship mode 前写入外部 Flash 的 LittleFS；
  保存记录绑定电池模型 CRC，模型或格式不兼容时会安全丢弃旧状态
- 单次连续充电期间百分比不会下降；单次连续放电期间百分比不会上升
- 充电状态准确
- 船模式关闭设备

### 8. 马达测试

**目的**: 测试振动马达

**命令**:
```bash
motor on             # 开启马达
motor off            # 关闭马达
motor pulse <ms>     # 脉冲持续时间
motor pattern <short|double|long|sos|alert>  # 播放图案
motor test           # 运行马达测试
```

**预期结果**:
- 马达正确开启/关闭
- 脉冲持续时间准确
- 图案按预期播放

### 9. USB 大容量存储测试

**目的**: 将 SD 卡作为 USB 驱动器暴露给 PC，直接访问文件

**命令**:
```bash
usb msc on       # 卸载 SD，启用 USB MSC (SD 显示为 USB 驱动器)
usb msc off      # 禁用 USB MSC，重新挂载 SD 卡
usb status       # 显示 USB 和 SD 卡状态
```

**使用方法**:
1. 录制音频到 SD: `mic record 5`
2. 启用 USB MSC: `usb msc on`
3. 将 USB 线缆连接到 PC - SD 卡显示为 USB 大容量存储
4. 从驱动器复制文件
5. 在 PC 上安全弹出驱动器，然后: `usb msc off`

**注意事项**:
- USB MSC 和文件系统不能同时访问 SD 卡
- 再次录音前必须先禁用 MSC
- UART shell (921600 波特率) 使用独立 UART，不是 USB

### 10. SPI Flash 测试

**目的**: 测试 SPI Flash (PY25Q64H 8MB) 的裸读写/擦除性能与完整性

**命令**:
```bash
flash speed            # 速度测试，960KB（默认且为最大值）
flash speed 512        # 速度测试，512KB
flash speed 64         # 速度测试，64KB
flash test             # 快速 PASS/FAIL 自检
```

**速度测试流程**（`flash speed`）:
1. 擦除测试区（4KB 扇区）
2. 写入测试图案
3. 读回并验证数据完整性
4. 以 KB/s 报告擦除/写/读速度

**PASS/FAIL 测试**（`flash test`）：在测试偏移处擦除一个 4KiB 块，写入 256 字节图案，
读回并比对。打印 `PASS:` 或带失败步骤的 `FAIL:`——适合作为产测的一次性检查。

**注意事项**:
- 测试使用未使用的 960KB 外部 Flash OTA app slot（偏移 `0x000000`）
- 不会触碰偏移 `0x130000` 处的 LittleFS 分区（保存电量计状态）
- 4KB 块大小与擦除扇区对齐
- 最大测试容量：960KB

### 11. 晶振负载电容调校

**目的**: 调校 LFXO (32.768kHz) 与 HFXO (32MHz) 晶振的内部负载电容。板子没有外部负载电容——必须通过寄存器配置内部电容。

**LFXO 命令**（32.768kHz 晶振）:

```bash
lfxo get                # 读取当前电容设置
lfxo set <0-3>          # 设置电容 (0=外部, 1=6pF, 2=7pF, 3=9pF)
```

**HFXO 命令**（32MHz 晶振）:

```bash
hfxo get                # 读取当前电容设置
hfxo set <pF>           # 以 pF 设置电容 (7.0-20.0, 步进 0.5, 0=外部)
```

**示例**:
```bash
uart:~$ lfxo get
LFXO capacitance: 0 (external)
uart:~$ lfxo set 2
LFXO capacitance set to: 2 (7pF)
uart:~$ hfxo get
HFXO capacitance: external
uart:~$ hfxo set 9.0
HFXO capacitance set to: 9.0 pF (CAPVALUE=90)
```

**调校完成后**，在设备树中配置最优值：
```dts
&lfxo {
    load-capacitors = "internal";
    load-capacitance-picofarad = <7>;
};
&hfxo {
    load-capacitors = "internal";
    load-capacitance-picofarad = <9>;
};
```

## 故障排除

### PMIC 船模式

**重要**: 进入船模式 (`pmic ship`) 后，设备将关闭电源。要唤醒:
- 连接 USB 线缆
- 按按钮
- 施加电压到 VBUS

### SD 卡问题

**症状**: 卡未挂载或错误

**解决方案**:
1. 检查卡是否正确插入
2. 尝试重新格式化为 FAT32
3. 移除卡前使用 `sd umount`
4. 检查瞬时同步错误 (这些是正常的)

### WiFi 连接失败

**症状**: 无法连接到 WiFi

**解决方案**:
1. 检查 SSID 和密码是否正确
2. AP 同时支持 2.4GHz（信道 1-13）和 5GHz（36-165）；默认 5GHz 信道 36。若客户端只支持 2.4G，用 `wifi on 6`（或 1-13 任一）
3. 检查天线是否连接
4. 尝试 `wifi on` 后 `wifi status`；用 `wifi scan` 查看周围网络

## 硬件规格

### 引脚分配

| 功能 | GPIO | 描述 |
|------|------|------|
| 按钮 | GPIO1.15 | 用户按钮 (低电平有效) |
| 马达控制 | GPIO1.6 | 振动马达控制 (通过 PMIC GPIO) |
| 麦克风 VDD_EN | GPIO1.14 | 麦克风电源使能 (GPIO 控制) |
| OLED VDD_EN | GPIO1.8 | OLED 电源使能 (GPIO 控制) |
| RFSW VDD_EN | GPIO0.29 | WiFi RF 开关使能 (GPIO 控制) |

### I2C 设备

| 设备 | 地址 | 总线 | 描述 |
|------|------|------|------|
| NPM1300 PMIC | 0x6B | I2C1 | 电源管理 IC |
| CH1115 OLED | 0x3C | I2C2 | 显示控制器 |

### 电源供应

- **USB**: 5V VBUS 用于充电和主电源
- **电池**: 由 NPM1300 管理的 Li-Po 电池
- **PMIC 调节器** (NPM1300):
  - BUCK1: MOTOR_3V3 (振动马达)
  - BUCK2: VDD_3V3 (主系统)
  - LDO1: VDDMIC_1V8 (麦克风)
  - LDO2: VDD_SD (SD 卡)
- **GPIO 控制的调节器**:
  - Mic VDD_EN: GPIO1.14 (麦克风电源使能)
  - OLED VDD_EN: GPIO1.8 (OLED 显示电源使能)
  - RFSW VDD_EN: GPIO0.29 (WiFi RF 开关使能)

### SYSTEM OFF 功耗测试

正常关机请使用：

```bash
sys stop
```

进入 nRF5340 SYSTEM OFF 前，该命令会先关闭 nRF7002 WiFi 供电域（BUCKEN、IOVDD 和
RF switch），再卸载并反初始化 SD 卡、挂起 SPI4（通过 sleep pinctrl 拉低
SCK/MOSI/MISO）、将 SD CS 拉低，并关闭 nPM1300 LDO2（`VDD_SD`）。这样可避免已
断电的 SD 卡被 SPI 信号反向供电。该命令进入的是 CPU SYSTEM OFF，不是 nPM1300 ship
mode。

`sys sd_stop` 执行相同流程，并打印每一步的返回值，供诊断使用。

全部 `sys` 子命令（`sys <sub>`）——每个变体先关闭其对应供电域再进入 SYSTEM OFF，
用于测量该项对静态电流的贡献：

| 命令 | 描述 |
|------|------|
| `sys stop` | 全部外设关断后 SYSTEM OFF |
| `sys uart_stop` | 挂起 UARTE 后 SYSTEM OFF |
| `sys wifi_stop` | 切断 nRF7002 供电后 SYSTEM OFF |
| `sys oled_stop` | 切断 OLED VDD 后 SYSTEM OFF |
| `sys mic_stop` | 切断麦克风 LDO1 后 SYSTEM OFF |
| `sys ble_stop` | 停止 BLE 后 SYSTEM OFF |
| `sys buck_pfm_stop` | 设置 BUCK2 PFM 后 SYSTEM OFF |
| `sys sd_status` | 显示 SD/PMIC 设备初始化状态（不关机） |
| `sys sd_stop` | 打印 SD 关断步骤后 SYSTEM OFF |

若要不重新烧录就退出 SYSTEM OFF 恢复运行，请使用普通 `reboot` 命令（重启设备），
而不是某个 `sys *_stop` 变体。

## 内存使用

截至 2026-08-19 的 pristine 构建：

```
FLASH:      934 KB (91.2% of 1 MB)
RAM:        375 KB (83.8% of 448 KB)
```

## 测试覆盖矩阵

| 模块 | 电源 | 通信 | 配置 | 读取 | 写入 |
|------|------|------|------|------|------|
| BLE | ✓ | ✓ | ✓ | - | - |
| WiFi | ✓ | ✓ | ✓ | - | - |
| SD 卡 | ✓ | - | - | ✓ | ✓ |
| 麦克风 | ✓ | - | ✓ | ✓ | ✓ |
| 按钮 | ✓ | - | - | ✓ | - |
| OLED | ✓ | ✓ | ✓ | - | - |
| PMIC | - | ✓ | ✓ | ✓ | ✓ |
| 马达 | ✓ | - | - | - | - |
| USB MSC | - | ✓ | ✓ | - | ✓ |
| Flash | ✓ | - | - | ✓ | ✓ |

## 内置 Shell 命令

以下 Zephyr 内置 shell 命令可用于底层硬件测试。

### Regulator Shell

控制 PMIC 调节器 (BUCK1/2、LDO1/2) 和 GPIO 固定调节器 (mic、oled、rfsw):

```bash
regulator status         # 列出所有调节器及其状态
regulator enable <name>  # 启用调节器
regulator disable <name> # 禁用调节器
regulator vget <name>    # 获取调节器电压
```

调节器名称 (来自设备树):
| 名称 | 类型 | 控制对象 |
|------|------|----------|
| `BUCK1` | NPM1300 | 马达 3.3V |
| `BUCK2` | NPM1300 | 主系统 3.3V (always-on) |
| `LDO1` | NPM1300 | 麦克风 1.8V |
| `LDO2` | NPM1300 | SD 卡 3.3V |
| `mic_vdd` | GPIO 固定 | 麦克风电源使能 (GPIO1.14) |
| `oled_vdd` | GPIO 固定 | OLED 电源使能 (GPIO1.8) |
| `rfsw_vdd` | GPIO 固定 | WiFi RF 开关 (GPIO0.29) |

### GPIO Shell

```bash
gpio get <port> <pin>       # 读取 GPIO 引脚状态
gpio set <port> <pin> <0|1> # 设置 GPIO 输出
gpio conf <port> <pin> <cfg> # 配置 GPIO 引脚
```

示例:
```bash
gpio set gpio1 14 1   # 开启麦克风电源
gpio set gpio1 8 0    # 关闭 OLED 电源
gpio get gpio1 15     # 读取按钮状态
```

### I2C Shell

```bash
i2c scan i2c1       # 扫描 I2C1 总线 (PMIC @ 0x6B)
i2c scan i2c2       # 扫描 I2C2 总线 (OLED @ 0x3C)
i2c read i2c1 0x6b <reg> <len>   # 读取 NPM1300 寄存器
i2c write i2c1 0x6b <reg> <data> # 写入 NPM1300 寄存器
```

## 开发说明

### 添加新测试

1. 在 `tests/clip/src/` 中创建源文件
2. 在 `tests/clip/src/` 中创建头文件
3. 添加到 CMakeLists.txt
4. 在 main.c 中初始化
5. 添加 shell 命令

### 代码风格

- 遵循 Zephyr 编码风格
- 使用 LOG_MODULE_REGISTER 进行日志记录
- 错误时返回负 errno
- 使用 device_is_ready() 检查设备

### Shell 命令

使用 SHELL_CMD_* 宏进行 shell 命令注册:
- SHELL_CMD: 简单命令
- SHELL_CMD_ARG: 带参数的命令
- SHELL_STATIC_SUBCMD_SET_CREATE: 子命令层次结构

## 版本历史

- 2026-08-19: 每台设备独立标识——BLE 名与 AP SSID 改为取自 chip_id（FICR）的 `Clip_<6位hex>`；新增 `ident` 命令
- 2026-07-16: 为硬件测试 OLED 添加持久化、基于模型的电量显示
- 2026-07-10: 适配 NCS v3.3.0（构建环境）；补充 `sd verify`/`sd test`/`sd patterns` 可靠性套件、`wifi on [channel]`（支持 2.4GHz）和 `wifi scan`；移除 IMU 相关内容（最终设备无 IMU）
- 2026-05-12: 添加 SPI Flash 速度测试命令
- 2026-05-11: 添加 LFXO/HFXO 晶振负载电容调校命令
- 2026-05-08: 添加 USB MSC 模块 (SD 卡作为 USB 驱动器)，添加 WAV 录音功能
- 2026-04-22: 更新文档以准确反映实现的特性，移除不存在的 BLE 和 WiFi 扫描命令，更正 SD 卡命令
- 2025-03-09: 添加振动马达、PMIC (NPM1300)、OLED 测试命令；添加软件 I2C 的 IMU 测试模块（已移除——最终设备无 IMU）
- 2023: 初始测试套件框架

## 许可证

Copyright (c) 2023 Nordic Semiconductor ASA

SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
