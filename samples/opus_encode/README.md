# Opus Streaming Encoder for ReSpeaker Lav

实时音频编码和流式传输应用，使用 Opus 编码器将麦克风数据编码后通过 UART 发送。

## 功能特性

- **实时流式编码**：DMIC 采集 → Opus 编码 → UART 传输，无需大缓冲
- **三种音频模式**：
  - `mono` - 单声道（仅左麦克风）
  - `stereo` - 立体声（左+右麦克风）
  - `merge` - 混合模式（左右麦克风平均）
- **流控支持**：支持启动/停止/退出命令
- **编码统计**：实时显示每帧编码时间（最小/最大/平均）
- **自动命名**：Python 接收脚本按日期时间自动命名文件

## 硬件配置

- **MCU**: nRF5340 (Cortex-M33 @ 64MHz)
- **DMIC**: 立体声 PDM 麦克风阵列
- **采样率**: 16 kHz
- **帧大小**: 20 ms (320 samples/帧)
- **波特率**: 921600 (见 `boards/respeaker_nrf5340_cpuapp.overlay`)

## 内存使用

- **FLASH**: ~173 KB (16.5%)
- **RAM**: ~60 KB (13.4%)
- **DMIC 缓冲**: 8 blocks × 1280 bytes = 10 KB

## 构建

```bash
source ~/ncs/v3.2.1/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)
west build --build-dir build-opus --board respeaker/nrf5340/cpuapp samples/opus_encode
```

## 刷写

```bash
west flash --build-dir build-opus && nrfutil device reset
```

## 使用方法

### 设备命令（串口输入）

在串口终端（minicom/screen/picocom）中输入：

| 命令 | 功能 |
|------|------|
| `1` | 切换到单声道模式（左声道） |
| `2` | 切换到立体声模式 |
| `3` | 切换到混合模式（左右平均） |
| `s` | 开始录音 |
| `e` | 停止录音 |
| `q` | 退出程序 |

### Python 接收脚本

```bash
# 安装依赖
pip install pyserial opuslib

# 单声道录音（左麦克风）
python3 samples/opus_encode/receive_opus.py /dev/ttyACM1 921600 . --mode mono

# 立体声录音
python3 samples/opus_encode/receive_opus.py /dev/ttyACM1 921600 . --mode stereo

# 混合模式录音
python3 samples/opus_encode/receive_opus.py /dev/ttyACM1 921600 . --mode merge
```

脚本会自动：
1. 发送模式命令给设备
2. 发送开始命令
3. 接收并解码 Opus 数据
4. 按 Ctrl+C 停止并保存为 WAV 文件

输出文件名格式：`recording_YYYYMMDD_HHMMSS.wav`

## 数据协议

### 头部信息

```
>>> OPUS_STREAM_START
SAMPLE_RATE=16000
CHANNELS=1 或 2
FRAME_SIZE=320
BITRATE=24000 或 48000
>>> DATA_START
```

### 编码帧格式

```
<4位十六进制长度>\n
<十六进制数据>\n
```

示例：
```
0039
4ca7fd29c02216ac18a8d75f3f5edbcb0cb35dd54bbecb791c5b3b1a5f2615edfceb37...
```

### 结束标记

```
>>> DATA_END
```

## 模式详解

### Mono（单声道）

- **声道数**: 1
- **码率**: 24000 bps
- **说明**: 仅使用左麦克风数据
- **用途**: 单麦克风录音，节省带宽

### Stereo（立体声）

- **声道数**: 2
- **码率**: 48000 bps
- **说明**: 保留左右麦克风完整数据
- **用途**: 立体声录音，需要方向信息

### Merge（混合）

- **声道数**: 1
- **码率**: 24000 bps
- **说明**: 左右声道数据平均混合
- **处理**: `(L + R) / 2`，带饱和保护
- **用途**: 全向收音，减少方向性

## 性能参考

根据实际测试，编码时间（包含处理）：

| 模式 | 平均时间 | 说明 |
|------|---------|------|
| mono | ~8-12 ms | 仅左声道提取 |
| stereo | ~11-13 ms | 立体声编码 |
| merge | ~11-13 ms | 混合 + 单声道编码 |

20ms 帧周期，编码有足够余量。

## 项目结构

```
samples/opus_encode/
├── src/
│   └── main.c              # 主程序
├── boards/
│   └── respeaker_nrf5340_cpuapp.overlay  # UART波特率配置
├── CMakeLists.txt
├── prj.conf                 # Zephyr配置
└── receive_opus.py          # Python接收脚本
```

## 依赖

- Zephyr RTOS v3.2.1
- nRF Connect SDK
- Opus 1.5 编解码库（位于 `lib/opus/`）
- pyserial (Python)
- opuslib (Python)

## 故障排除

### 串口权限

```bash
sudo usermod -a -G dialout $USER
# 重新登录生效
```

### 设备无响应

```bash
# 重置设备
nrfutil device reset
```

### 波特率不匹配

检查 `boards/respeaker_nrf5340_cpuapp.overlay`:
```dts
&uart0 {
    current-speed = <921600>;
};
```

## 许可证

Apache-2.0
