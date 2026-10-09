# reSpeaker Clip — BLE AT 协议规范（中文版）

> 本文件是 [`protocol.md`](protocol.md) 的中文译本，与固件 `applications/clip/src/at_commands.c` 同步审核更新。
> 两者如有出入，以英文原版为准；代码块、字段名、错误消息均为设备实际字节，不翻译。

## 1. 协议概述

### 1.1 设计原则

reSpeaker Clip 使用基于 JSON 的 AT 命令协议在移动应用与设备之间通信。所有命令遵循 Hayes AT 命令标准，并采用统一的 JSON 响应格式。

**核心设计原则：**
- **人类可读**：JSON 格式，便于调试与解析
- **可扩展**：新增命令不破坏兼容性
- **非阻塞**：文件传输期间可并发处理命令
- **健壮**：完整的错误处理与恢复
- **高效**：二进制数据走独立特征值传输

### 1.2 传输层（BLE GATT）

> **传输通道：** AT 命令运行在三种传输通道上 —— BLE GATT（本节）、WiFi UDP（附录 D）、USB CDC ACM 串口。三者汇入同一个 AT 服务器；响应的活跃通道按响应自动选择，优先级 **UDP > BLE**（对 AT 命令而言 USB CDC 与 BLE 行为一致）。文件传输使用 BLE File Data 特征值或 UDP 二进制帧。

**服务 UUID**：`6E400001-B5A3-F393-E0A9-E50E24DCCA9E`

协议以 BLE GATT 作为传输层，提供三个特征值：
1. **命令接收**（Write）：App 向设备发送 AT 命令
2. **响应发送**（Notify）：设备发送 JSON 响应与进度
3. **文件数据**（Notify）：设备流式发送二进制文件数据

### 1.3 命令语法

支持三种命令类型：

| 类型 | 格式 | 示例 | 说明 |
|------|------|---------|-------------|
| EXEC | `AT+XX` | `AT+GSTAT` | 无参数执行 |
| SET | `AT+XX=<value>` | `AT+MODE=enhanced` | 设置参数 |
| GET | `AT+XX?` | `AT+MODE?` | 查询当前参数 |

### 1.4 响应格式

所有响应使用统一 JSON 格式：

**通用响应模式：**
```json
{
  "ok": true,
  "data": { ... }
}
```

> `"data"` 的值由响应构造器原样插入，具体形状随命令而异（对象、字符串或省略）。人类可读消息（信息性与错误）一律使用 `"msg"` 键，从不使用 `"error"`。

**成功响应：**
```json
{
  "ok": true,
  "data": { ... }
}
```

**错误响应：**
```json
{
  "ok": false,
  "msg": "Error message"
}
```

### 1.5 错误处理

所有错误返回 `"ok": false` 且带描述性 `"msg"` 字段（如 `{"ok":false,"msg":"SD card not mounted"}`）。**没有数字错误码** —— 处理器只返回消息字符串。少数命令在成功时也通过 `"msg"` 返回信息性消息（如 `AT+FACTORY`、`AT+NAME` 清除）。

### 1.6 参考实现

完整的 Python SDK 与主机工具位于 `applications/clip/tests/`（用法见其 `README.md` 与 `EXAMPLES.md`）：
- `applications/clip/tests/tools/ble_terminal.py` — BLE 交互式 AT 终端
- `applications/clip/tests/tools/udp_terminal.py` — WiFi UDP 通道同款终端
- `applications/clip/tests/tools/udp_sync.py` — WiFi UDP 批量文件同步
- `applications/clip/tests/tools/record.py` — 远程录音控制
- `applications/clip/tests/tools/clip-cli.py` — 脚本化命令行客户端

底层客户端库（`client.py`、`commands.py`、`transfer.py`、`codec.py`、`wifi.py`）在 `applications/clip/tests/clip/`，是任何新客户端实现的参考。

## 2. BLE GATT 服务定义

### 2.1 服务 UUID：6E400001-B5A3-F393-E0A9-E50E24DCCA9E

该自定义 UUID 定义 reSpeaker Clip 通信服务。

### 2.2 特征值

#### 2.2.1 命令接收（Write）

**UUID**：`6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
**属性**：Write
**最大长度**：512 字节
**用途**：接收来自移动 App 的 AT 命令

App 向该特征值写入 AT 命令字符串。每次写入按一条完整命令处理。

#### 2.2.2 响应发送（Notify）

**UUID**：`6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
**属性**：Notify
**最大长度**：MTU - 3（MTU 247 时通常为 244 字节）
**用途**：发送 JSON 响应与进度通知

设备在此发送：
- 命令响应（成功/错误）
- 文件传输期间的进度
- 主动事件通知

#### 2.2.3 文件数据（Notify）

**UUID**：`6E400004-B5A3-F393-E0A9-E50E24DCCA9E`
**属性**：Notify
**最大长度**：MTU - 3（MTU 247 时通常为 244 字节）
**用途**：文件传输期间流式发送二进制帧

二进制帧经此特征值发送。每个通知携带一帧，以首字节（帧类型）标识。完整二进制帧协议见第 4 节。

此特征值上的帧类型：
- `0x01` DATA — 文件数据块
- `0x10` FILE_START — 文件传输开始
- `0x11` FILE_END — 文件结束（带 CRC32）
- `0x12` TRANSFER_DONE — 全部文件完成
- `0x13` STREAM_START — RTC 实时流开始
- `0x14` STREAM_DATA — RTC 实时 Opus 帧
- `0x15` STREAM_END — RTC 实时流结束

#### 2.2.4 音频可视化（Notify）

**UUID**：`6E400005-B5A3-F393-E0A9-E50E24DCCA9E`
**属性**：Notify
**最大长度**：MTU - 3（MTU 247 时通常为 244 字节）
**用途**：实时音频能量可视化数据

录音激活时每 ~100 ms 发送 7 字节打包的音频能量。

**数据格式（7 字节）：**
```
[byte0] [byte1] [byte2] [byte3] [byte4] [byte5] [byte6]
  H L     H L     H L     H L     H L     H L     H _
```

- 每字节含两个 4-bit 半字节值（高半字节 = 偶数下标，低半字节 = 奇数下标）
- 6 字节 × 2 值 + 1 字节 × 1 值 = **13 个音频能量值**
- 取值范围：0–10（每个频带的能量级）
- 更新率：录音激活时 ~100 ms
- 空闲：不发送

**解码示例（Python）：**
```python
values = []
for i in range(6):
    values.append(data[i] >> 4)       # 高半字节
    values.append(data[i] & 0x0F)     # 低半字节
values.append(data[6] & 0x0F)         # 第 13 个值（末字节低半字节）
```

### 2.3 连接要求

**广播名称：** `Clip XXXX` —— 字面字符串 `Clip` 加空格加 nRF5340 FICR DEVICEID 低 16 位的 4 个十六进制位（如 `Clip A1B2`）。WiFi AP SSID 使用同一后缀（`ClipAP_A1B2`）。

| 要求 | 规格 |
|-------------|---------------|
| 配对 | LE Secure Connections，**Just Works**（未鉴权）—— 见下文 |
| 绑定 | 必需（持久化用于自动重连，单绑定槽） |
| 加密 | AES-128 CCM，Level 2（强制） |
| MTU | 可协商至 517（默认 23） |
| 连接间隔 | 15-80 ms（自适应） |

**配对/关联模型（客户端应有的预期）：**

- 设备是安全发起方：连接建立后其 `connected()` 回调立即调度安全请求，调用 `bt_conn_set_security(conn, BT_SECURITY_L2)`（加密，未鉴权）。
- 设备无配对用的显示/键盘，只注册了自动确认的 `pairing_confirm` 回调（无 passkey 显示 / 数字比较回调），因此关联方式是 LE Secure Connections 上的 **Just Works**（中央设备支持时）。没有 PIN 可输入，也没有用户确认数字。
- 配对**可绑定且仅有一个绑定槽**（`CONFIG_BT_BONDABLE=y`、`CONFIG_BT_MAX_PAIRED=1`、`CONFIG_BT_KEYS_OVERWRITE_OLDEST=y`）；密钥持久化在 settings。重连时设备用存储的 LTK 重新加密，若未达到加密级别（< 2 或配对错误）则断开链路——删除了绑定信息的客户端会被断开并须重新配对。

### 2.4 MTU 协商

设备应将 MTU 协商到最优值：
- **默认 MTU**：23 字节（BLE 规范）
- **最大 MTU**：517 字节（nRF5340 支持）
- **推荐 MTU**：247 字节（吞吐最优）

MTU 越大 = 通知越少 = 吞吐越高。

## 3. 命令协议

### 3.1 命令类型（EXEC、SET、GET）

#### EXEC 命令（无参数）
格式：`AT+XX`

执行操作或获取状态：
- `AT+GSTAT` - 获取设备状态
- `AT+DEVICE` - 获取设备名
- `AT+VERSION` - 获取版本信息
- `AT+START` - 开始录音（使用当前模式）
- `AT+STOP` - 停止录音
- `AT+MARK` - 添加书签
- `AT+PAUSE` - 暂停录音
- `AT+RESUME` - 恢复录音
- `AT+CANCEL` - 取消传输
- `AT+LIST` - 列出会话/文件
- `AT+MARKS` - 获取会话书签
- `AT+DOWNLOAD` - 下载文件
- `AT+DELETE` - 删除会话
- `AT+FORMAT` - 格式化 SD 卡
- `AT+POWEROFF` - 关机
- `AT+REBOOT` - 重启
- `AT+DFU` - 重启进入 MCUboot DFU/恢复模式
- `AT+WIFI` - 开启 WiFi AP（等价 `AT+WIFI=on`）
- `AT+USB` - 启用 USB CDC+MSC

#### SET 命令（带参数）
格式：`AT+XX=<value>`

设置配置或带参执行：
- `AT+MODE=<normal|enhanced>` - 设置录音模式（`AT+START=<mode>` 另接受旧别名 `stereo`/`merge`）
- `AT+AUTODEL=<off|0|1-30>` - 设置自动删除策略
- `AT+BRIGHTNESS=<0-255>` - 设置 OLED 亮度
- `AT+TIME=<unix_ts>` - 设置系统时间
- `AT+PAIR=<reset>` - 重置 BLE 配对
- `AT+FACTORY=<confirm>` - 恢复出厂
- `AT+START=<mode>` - 以指定模式开始录音
- `AT+MARK=<note>` - 添加带备注书签
- `AT+DELETE=<session>` - 删除会话
- `AT+LIST=<session>` - 查看会话详情
- `AT+MARKS=<session>` - 获取会话书签
- `AT+DOWNLOAD=<session/file>` - 下载文件
- `AT+WIFI=<on|off>` - 开关 WiFi AP
- `AT+USB=<on|off>` - 启停 USB CDC+MSC
- `AT+LOG=<off|info|debug>` - 设置 SD 日志后端级别

#### GET 命令（查询）
格式：`AT+XX?`

查询当前配置：
- `AT+DEVICE?` - 获取设备名
- `AT+NAME?` - 获取用户自定义设备名
- `AT+MODE?` - 获取当前模式
- `AT+AUTODEL?` - 获取自动删除策略
- `AT+BRIGHTNESS?` - 获取 OLED 亮度
- `AT+TIME?` - 获取当前时间
- `AT+PAIR?` - 获取配对状态
- `AT+WIFI?` - 获取 WiFi AP 状态
- `AT+USB?` - 获取 USB 状态
- `AT+LOG?` - 获取 SD 日志后端状态

### 3.2 JSON 消息格式

所有响应使用结构一致的 JSON：

**成功（带数据）：**
```json
{
  "ok": true,
  "data": {
    "key": "value"
  }
}
```

**成功（无数据）：**
```json
{
  "ok": true
}
```

**错误：**
```json
{
  "ok": false,
  "msg": "Error message description"
}
```

**注意：** 文件传输进度通过文件数据特征值上的二进制帧传递（见第 4 节），不走 JSON 响应。

### 3.3 命令参考

#### 3.3.1 状态命令

##### AT+GSTAT - 获取设备状态

获取当前设备状态与信息。

**请求：**
```
AT+GSTAT
```

**响应：**
```json
{
  "ok": true,
  "data": {
    "state": "IDLE",
    "recording": false,
    "session": null,
    "duration": 0,
    "battery": 85,
    "charging": true,
    "temp": 26,
    "voltage": 3980,
    "mode": "normal",
    "bitrate": 16000,
    "free_space": 1024,
    "device": "Clip"
  }
}
```

**字段：**
- `state`：当前设备状态（IDLE/RECORDING/TRANSMITTING/WIFI_SYNC/PAUSED/ERROR；OTA 已定义但上传期间不会进入）
- `recording`：是否正在录音（true/false）
- `session`：当前会话 ID 或 null —— **仅在录音中上报**；停止后为 `null`（最后的会话 ID 仅在设备内部为停止通知保留，不再上报）
- `duration`：当前录音秒数 —— 仅录音中有效；停止后为 `0`
- `battery`：电量百分比（0-100）
- `charging`：充电状态（true/false）。注意：电池充满时即使插着 USB 也为 false —— 关机门控看的是 VBUS 在场，不是此字段
- `temp`：电池温度 °C（NPM1300 NTC）
- `voltage`：电池电压 mV
- `mode`：录音模式（normal/enhanced）
- `bitrate`：当前模式码率（normal=16000，enhanced=32000）
- `free_space`：剩余空间 MB
- `device`：设备名字符串

**错误情况：**
- 从不失败（总是返回当前状态）

---

##### AT+TIME - 系统时间

获取或设置系统时间（Unix 时间戳）。

**请求（设置）：**
```
AT+TIME=1706918430
```

**请求（查询）：**
```
AT+TIME?
```

**响应（设置）：**
```json
{
  "ok": true,
  "data": { "time": 1706918430 }
}
```

**响应（查询）：**
```json
{
  "ok": true,
  "data": { "time": "2024-02-03T10:00:30Z" }
}
```

> 设置时在 `data.time` 回显 Unix 时间戳（整数）；查询返回 `data.time` 中的 ISO-8601 字符串。若从未设置过时间，查询返回
> `{"ok":false,"msg":"Time not set (use AT+TIME=<timestamp>)"}`。

**错误情况：**
- `{"ok":false,"msg":"Missing timestamp"}` / `"Invalid timestamp"` / `"Invalid time"`

---

##### AT+VERSION - 版本信息

获取固件版本。

**请求：**
```
AT+VERSION
```

**响应：**
```json
{
  "ok": true,
  "firmware": "0.0.6"
}
```

**字段：**
- `firmware`：固件版本字符串（唯一返回字段）

---

##### AT+BATT - 电池状态

获取当前电池状态（SoC %、充电状态、电压、温度）。

**请求：**
```
AT+BATT
```

**响应：**
```json
{
  "ok": true,
  "data": {
    "battery": 85,
    "charging": true,
    "voltage": 3980,
    "temp": 26
  }
}
```

**字段：**
- `battery`：电量百分比（0-100，电量计 SoC 估计）
- `charging`：充电状态（true/false）
- `voltage`：电池电压 mV
- `temp`：电池温度 °C（NPM1300 NTC；可用于验证充电截止）

> 数值来自电池模块的周期轮询（NPM1300 + nRF Fuel Gauge），适合现场/调试热监测。

---

##### AT+STORAGE - SD 卡存储信息

获取 SD 卡存储统计。用 `AT+STORAGE?`（或裸 `AT+STORAGE`）。

**请求：**
```
AT+STORAGE?
```

**响应：**
```json
{
  "ok": true,
  "data": {
    "mounted": true,
    "total_mb": 15193,
    "free_mb": 14000,
    "used_mb": 1193,
    "used_pct": 7,
    "recorded_mb": 980
  }
}
```

**字段：**
- `mounted`：SD 卡当前是否挂载（见说明）
- `total_mb`：卡容量 MB
- `free_mb`：剩余空间 MB
- `used_mb`：已用空间 MB（`total - free`）
- `used_pct`：已用百分比（0-100）
- `recorded_mb`：全部会话已录音总量 MB

> SD 卡空闲断电（未挂载）时，返回最后已知的 `total_mb`/`free_mb` 且 `"mounted": false`。
> `total_mb`/`free_mb` 为 0 表示开机从未见过卡。

**错误情况：**
- `{"ok":false,"msg":"Use AT+STORAGE?"}`（任何 SET 参数）
- `{"ok":false,"msg":"Storage unavailable"}`

---

#### 3.3.2 录音控制

##### AT+START - 开始录音

开始一段新的录音会话。

**请求：**
```
AT+START=normal
```

**参数：**
- `mode`："normal"、"enhanced" 或 "rtc"（旧别名："stereo" = normal，"merge" = enhanced；均不区分大小写）。省略 → 当前模式。
  `rtc` 启动实时流而非 SD 录音 —— 仅限 BLE，且要求文件数据特征值已订阅（见 4.8 节）。按键无法启动 RTC；按键长按松开永远走 SD 管线。

**响应：**
```json
{
  "ok": true,
  "data": {
    "session": "20240203100000"
  }
}
```

RTC 会话额外返回模式：

```json
{
  "ok": true,
  "data": {
    "session": "20240203100000",
    "mode": "rtc"
  }
}
```

> `data` 只含 `session` id（id 尚未就绪时为空对象）。

**错误情况：**
- `{"ok":false,"msg":"invalid mode (normal/stereo/enhanced/merge)"}`（模式参数错误）
- `{"ok":false,"msg":"Already recording or invalid state"}` / `"Audio module busy"` / `"Failed to start recording"`
- `"WiFi active, cannot record"` / `"USB MSC active, disable USB first"`（WiFi/USB 活动期间禁止录音）
- `"RTC requires BLE connected and file data notify enabled"`（RTC 前置条件不满足）

**状态变化：** IDLE → RECORDING（状态广播 `"RECORDING"`；RTC 会话为 `"STREAMING"`）

**副作用：**
- 创建新会话目录
- 初始化 session.json
- 启动音频采集
- 启用按键书签

---

##### AT+STOP - 停止录音

停止当前录音会话。

**请求：**
```
AT+STOP
```

**响应：**
```json
{
  "ok": true,
  "data": {
    "session": "20240203100000",
    "duration": 600,
    "frames": 1440000,
    "file_count": 1,
    "total_size": 3600000
  }
}
```

**字段：**
- `session`：会话 ID
- `duration`：录音时长秒
- `frames`：捕获的总音频帧数
- `file_count`：会话文件数（新停止时为 1）
- `total_size`：全部文件总字节

**错误情况：**
- `{"ok":false,"msg":"No active session"}` / `"Not recording"`

**状态变化：** RECORDING → IDLE

**副作用：**
- 终结 session.json
- 关闭全部文件
- 停止音频采集
- 关闭按键书签

---

##### AT+MARK - 添加书签

在当前录音位置添加书签。

**请求：**
```
AT+MARK
```

**响应：**
```json
{
  "ok": true,
  "data": {
    "offset": 123
  }
}
```

**字段：**
- `offset`：距会话开始的秒数

> 备注参数（`AT+MARK=<text>`）解析器接受但**不存储** —— 书签只记录 offset。书签按会话存于 `marks.bin`。

**错误情况：**
- `{"ok":false,"msg":"No active session"}` / `"Not recording"`（仅录音中可书签）
- `{"ok":false,"msg":"MARK not supported in RTC mode"}`（RTC 会话不落卡）

**副作用：**
- 写书签到 marks.bin
- 发送主动书签通知
- 触发震动反馈

---

#### 3.3.3 会话管理

##### AT+LIST - 列出会话/文件

分页列出全部会话、查看会话详情、或分页列出文件。

**请求（全部会话 - 第一页）：**
```
AT+LIST
```

**说明：** 会话按最新在前排序（按会话 ID 即时间戳降序）。每次请求即时枚举（无持久缓存）。

**请求（分页会话）：**
```
AT+LIST?2&10
```

**请求（会话详情）：**
```
AT+LIST=20240203100000
```

**请求（分页文件列表）：**
```
AT+LIST=20240203100000?1&20
```

**响应（会话分页）：**
```json
{
  "ok": true,
  "data": {
    "total": 50,
    "page": 1,
    "per_page": 10,
    "sessions": [
      {"id": "20240203120000", "files": 15, "size": 2621440, "bookmarks": 0},
      {"id": "20240203100000", "files": 30, "size": 5242880, "bookmarks": 5}
    ]
  }
}
```

**响应（会话详情）：**
```json
{
  "ok": true,
  "data": {
    "files": 30,
    "size": 5242880,
    "synced": 15,
    "bookmarks": 5,
    "channels": 2,
    "sample_rate": 16000,
    "mode": "normal"
  }
}
```

**响应（分页文件列表）：**
```json
{
  "ok": true,
  "data": {
    "total": 200,
    "page": 1,
    "per_page": 10,
    "files": [
      "0001.opus",
      "0002.opus",
      "0003.opus"
    ]
  }
}
```

**字段：**
- `total`：条目总数（会话或文件）
- `page`：当前页码（默认 1）
- `per_page`：每页条数（默认 10；会话列表上限 50，文件列表上限 20）
- `sessions`：会话对象数组（会话分页）
  - `id`：会话 ID
  - `files`：会话音频文件总数
  - `size`：全部文件总字节
  - `bookmarks`：会话书签数
- `files`：文件名数组（文件分页）
- `synced`：已成功传输的文件数（仅会话详情）
- `channels`：声道数 - 1=单声道，2=立体声（仅会话详情）
- `sample_rate`：采样率 Hz，如 16000（仅会话详情）
- `mode`：录音模式 - "normal"（立体声）或 "enhanced"（单声道 + DSP）（仅会话详情）

**用法示例：**
```
# 列出会话（默认：第 1 页，每页 10 条）
AT+LIST
# → {"total":50,"page":1,"per_page":10,"sessions":[...]}

# 第 2 页会话
AT+LIST?2&10
# → 第 11-20 条

# 会话详情（含 synced 计数与音频格式）
AT+LIST=20240203100000

# 分页文件（第 1 页，每页 10 条）
AT+LIST=20240203100000?1&10

# 从 synced 计数续传：synced=15 → 从 0016.opus 开始
AT+DOWNLOAD=20240203100000:0016.opus
```

**错误情况：**
- `{"ok":false,"msg":"Session not found"}` / `"Invalid session ID"` / `"SD card not mounted"` / `"Failed to list sessions"`

---

##### AT+DELETE - 删除会话

删除一段录音会话及其全部文件。

**请求：**
```
AT+DELETE=20240203100000
```

**响应：**
```json
{
  "ok": true,
  "data": { "deleted": true }
}
```

**错误情况：**
- `{"ok":false,"msg":"Session not found"}` / `"Invalid session ID"` / `"cannot delete active session"` / `"Missing session_id"` / `"SD card not mounted"`

**副作用：**
- 删除会话目录及全部文件
- 更新 GSTAT 会话计数

---

##### AT+MARKS - 获取会话书签

获取某会话的书签。支持摘要与分页两种形式。

**请求（摘要）：**
```
AT+MARKS=20240203100000
```

**响应（摘要）：**
```json
{
  "ok": true,
  "data": {
    "session": "20240203100000",
    "total": 50
  }
}
```

**请求（分页，第 1 页）：**
```
AT+MARKS=20240203100000?1&10
```

**响应（分页）：**
```json
{
  "ok": true,
  "data": {
    "total": 50,
    "page": 1,
    "per_page": 10,
    "bookmarks": [
      {"offset": 30},
      {"offset": 60}
    ]
  }
}
```

**字段：**
- `session`：会话 ID（摘要响应）
- `total`：书签总数
- `page`：当前页码（1 起）
- `per_page`：每页条数（默认 20，上限 100）
- `bookmarks`：书签数组；每条只有 `offset`（距会话开始的秒数）。不存储备注。

**分页逻辑：**
- 无 `?`：返回含总数的摘要
- 带 `?page&per_page`：返回指定页（默认 page=1、per_page=20；per_page 上限 100）
- 客户端递增 `page` 取下一页

**错误情况：**
- `{"ok":false,"msg":"Missing session_id"}` / `"Invalid session ID"` / `"Failed to get bookmark count"` / `"Failed to get bookmarks"` / `"SD card not mounted"`

---

#### 3.3.4 文件传输

##### AT+DOWNLOAD - 下载文件

启动设备到 App 的文件传输。两种模式（解析器只按 `:` 分割）：

**请求（整会话）：**
```
AT+DOWNLOAD=<session_id>
```

**请求（单文件 / 续传）：**
```
AT+DOWNLOAD=<session_id>:<filename>
```

**示例：**
```
# 下载会话全部文件
AT+DOWNLOAD=20250225143000

# 从指定文件下载/续传（跳过之前的文件）
AT+DOWNLOAD=20250225143000:0016.opus
```

> 只解析 `:` 分隔符。`/` 分隔（`session/file`）**不受支持** —— 单文件/续传模式请用 `:`。

**RTC 会话情形：**

若请求的会话是活动 RTC 会话（`AT+START=RTC`），该命令启动实时流而非文件传输（见 4.8 节）：

```json
{
  "ok": true,
  "data": { "state": "streaming", "session": "20250225143000" }
}
```

随后在文件数据特征值上发送 `STREAM_START` / `STREAM_DATA` 帧。RTC 会话拒绝 `session:filename` 形式（`"RTC session has no files"`）；RTC 流仅当命令经 BLE 到达时可用（否则 `"RTC streaming requires BLE"`）。

**续传逻辑：**
1. 客户端查询会话详情：`AT+LIST=<session_id>`
2. 响应含 `synced` 计数（如已传 15 个文件）
3. 客户端算下一文件：`synced + 1` → 0016.opus
4. 客户端发送：`AT+DOWNLOAD=<session_id>:0016.opus`
5. 设备从 0016.opus 起传输

**响应（启动，整会话）：**
```json
{
  "ok": true,
  "data": { "state": "transmitting", "session": "20250225143000" }
}
```

**响应（启动，单文件/续传）：**
```json
{
  "ok": true,
  "data": { "state": "transmitting", "session": "20250225143000", "file": "0016.opus", "total": 30, "bytes": 0 }
}
```

**传输中的二进制帧：**

启动响应之后，设备在文件数据特征值（`0x6E400004`）上发送二进制帧。完整帧协议见第 4 节。

**数据流：**
1. 设备在响应特征值上发送 JSON 启动响应
2. 每个文件：
   - 发送 `FILE_START` 帧（文件名 + 大小）
   - 发送 `DATA` 帧（文件数据块）
   - 发送 `FILE_END` 帧（全文件 CRC32）
3. 发送 `TRANSFER_DONE` 帧（session_id + file_count）
4. 客户端可用 `AT+DOWNLOAD=session:next_file` 续传

**断连/续传流程：**
1. 传输期间 BLE 断开
2. 设备自动取消传输
3. 设备继续录音（若处于 RECORDING）
4. 客户端重连
5. 客户端发送 `AT+DOWNLOAD=session:last_received_file`
6. 从下一文件恢复传输

**传输进行中重发 DOWNLOAD（幂等）：**

对**同一会话、同一传输通道上已在流式传输**的 `AT+DOWNLOAD`，设备回答 `{"ok":true}` 并附当前进度，不做任何变更 —— 主机在响应超时或 UI 重试后合法地重发，为一个相同请求打断正在运行的传输是错误的。对**不同会话或不同通道**（如 WiFi 切换时的旧 BLE 腿竞争）的重发**立即**以 `"Transfer already in progress"` 拒绝；传输暂停期间的重发同样拒绝（用 `AT+RESUME`）。任何忙路径都不会静默等待。

**错误情况：**
- `{"ok":false,"msg":"Transfer already in progress"}`（立即返回 —— 见上文） / `"Session or file not found"`
- `"Missing session_id"`、`"Invalid session ID"`、`"DOWNLOAD argument too long"`
- `"Invalid download filename"` —— 续传文件名必须形如 `NNNN.opus`，范围 `0001.opus` 到配置的最大块索引

**状态变化：** IDLE → TRANSMITTING

---

#### 3.3.5 录音控制（暂停/恢复/取消）

##### AT+PAUSE - 暂停录音

暂停进行中的录音。这只暂停**录音** —— 不是传输控制（传输用 `AT+CANCEL`；见 4.5 节）。

**请求：**
```
AT+PAUSE
```

**响应：**
```json
{
  "ok": true,
  "data": { "paused": true }
}
```

**状态变化：** RECORDING → PAUSED

**副作用：**
- 停止 DMIC 采集
- 关闭当前文件
- 会话保持打开
- 可用 `AT+RESUME` 恢复

> **RTC 会话：** 暂停会停止 BLE 流并丢弃全部缓冲帧，但麦克风管线保持运行。响应带
> `{"paused":true,"stream":true}`，设备状态保持 RECORDING。

**错误情况：**
- `{"ok":false,"msg":"Not recording"}` / `"Failed to pause recording"`

---

##### AT+RESUME - 恢复录音

恢复已暂停的**录音**（对文件传输无影响）。

**请求：**
```
AT+RESUME
```

**响应：**
```json
{
  "ok": true,
  "data": { "resumed": true }
}
```

**状态变化：** PAUSED → RECORDING

**副作用：**
- 以递增索引创建新文件
- 恢复 DMIC 采集
- 在同一会话内继续

> **RTC 会话：** 恢复会从当前帧重新启动 BLE 流。响应带 `{"resumed":true,"stream":true}`。

**错误情况：**
- `{"ok":false,"msg":"Not paused"}` / `"Failed to resume recording"`

---

##### AT+CANCEL - 取消传输

取消进行中的文件传输。

**请求：**
```
AT+CANCEL
```

**响应：**
```json
{
  "ok": true,
  "data": { "canceled": true }
}
```

**状态变化：** TRANSMITTING → IDLE

**副作用：**
- 关闭文件
- 丢弃进度
- 不创建 .transferred 标记

**错误情况：**
- `{"ok":false,"msg":"No active transfer"}` / `"Failed to cancel transfer"`

---

#### 3.3.6 存储管理

##### AT+AUTODEL - 自动删除策略

配置已传输会话的自动删除策略。

**请求（设置）：**
```
AT+AUTODEL=7
```

**请求（查询）：**
```
AT+AUTODEL?
```

**响应（设置/查询）：**
```json
{
  "ok": true,
  "data": { "autodel": 7 }
}
```

> `autodel` 为整数（天）或字符串 `"off"`。设置回显应用后的值。

**策略取值：**
| 值 | 说明 |
|-------|-------------|
| `off` | 仅手动删除（默认） |
| `0` | 传输后立即删除 |
| `1-30` | 传输后 N 天删除 |

**错误情况：**
- `{"ok":false,"msg":"Auto-delete must be 0-30 days or off"}` / `"Missing autodel value"`

---

#### 3.3.7 配置

##### AT+MODE - 录音模式

设置录音模式预设。

**请求（设置）：**
```
AT+MODE=enhanced
```

**请求（查询）：**
```
AT+MODE?
```

**响应（设置/查询）：**
```json
{
  "ok": true,
  "data": { "mode": "enhanced" }
}
```

**合法值：** "normal"、"enhanced"

**模式预设：**
- **Normal**：立体声（L+R 双声道），16kbps/声道（共 32kbps），复杂度 0，无 DSP 处理，10 分钟文件分段
- **Enhanced**：单声道（L+R 合并），32kbps，复杂度 1，DSP 开启（降噪 + 去混响），2 分钟文件分段

码率与复杂度按模式固定，构建期经 Kconfig 配置（`CONFIG_CLIP_NORMAL_BITRATE`、`CONFIG_CLIP_ENHANCED_BITRATE` 等），运行时不可改。

---

##### AT+BRIGHTNESS - OLED 亮度

获取或设置 OLED 亮度（对比度）。值存入 NVS，每次开机自动应用。

**请求（设置）：**
```
AT+BRIGHTNESS=<value>
```

**请求（查询）：**
```
AT+BRIGHTNESS?
```

**响应（设置）：**
```json
{
  "ok": true,
  "data": { "brightness": 200 }
}
```

**响应（查询）：**
```json
{
  "ok": true,
  "data": { "brightness": 128 }
}
```

**参数：**
- `brightness`：整数 0–255（0 最暗，255 最亮，默认 128）

**错误情况：**
- `{"ok":false,"msg":"Brightness must be 0-255"}` / `"Invalid brightness"` / `"Missing brightness value"`

---

##### AT+DEVICE - 设备名

获取设备名。

**请求：**
```
AT+DEVICE
```

**请求（查询）：**
```
AT+DEVICE?
```

**响应：**
```json
{
  "ok": true,
  "device": "Clip"
}
```

---

##### AT+NAME - 用户自定义设备名

设置或查询用户自定义设备名。持久化保存、重启保留。不影响 BLE 或 WiFi 命名。

**请求（设置）：**
```
AT+NAME=My Clip
```

**请求（清除）：**
```
AT+NAME=CLEAR
```

**请求（查询）：**
```
AT+NAME?
```

**响应（设置/查询）：**
```json
{
  "ok": true,
  "data": {"name": "My Clip"}
}
```

**校验规则：**
- 长度：1–256 字节
- 允许：可打印 UTF-8 字符（字母、数字、中日韩、空格、`-`、`_` 等）
- 不允许：控制字符（0x00–0x1F）、空字符串
- 参数两侧引号（`"..."`）会被剥掉，`AT+NAME="My Clip"` 等价于 `AT+NAME=My Clip`
- `AT+NAME=CLEAR` 删除名称（置空）

**错误情况：**
- `{"ok":false,"msg":"Missing name"}` / `"Name too long (max 256 bytes)"` / `"Invalid characters"` / `"Name cannot be empty"` / `"Save failed"`

---

##### AT+WIFI - WiFi AP 控制

控制用于本地文件传输的 WiFi 热点。

**请求（开启）：**
```
AT+WIFI=on
```

**请求（关闭）：**
```
AT+WIFI=off
```

**请求（查询）：**
```
AT+WIFI?
```

**响应（开启）：**
```json
{
  "ok": true,
  "data": {
    "ssid": "ClipAP_A1B2",
    "password": "aB3xK9mQ",
    "ip": "192.168.4.1",
    "port": 8089
  }
}
```

**响应（关闭）：**
```json
{
  "ok": true,
  "data": { "wifi": "off" }
}
```

**响应（查询）：**
```json
{
  "ok": true,
  "data": {
    "running": true,
    "ssid": "ClipAP_A1B2",
    "password": "aB3xK9mQ",
    "ip": "192.168.4.1",
    "port": 8089,
    "connected": true
  }
}
```

**字段：**
- `ssid`：WiFi SSID（ClipAP_XXXX，芯片 ID 后 4 个十六进制位）
- `password`：WPA2 密码 —— **每台设备首次开机随机生成**（8 个可打印字符，持久化在 settings；经 BLE 用 `AT+WIFI?` 读取）。不存在通用默认密码；丢失 settings 的设备会重新生成
- `ip`：AP 地址（192.168.4.1）
- `port`：UDP 传输端口（8089）
- `running`：AP 是否活动
- `connected`：是否有客户端连接

**状态变化：** IDLE → WIFI_SYNC（开）、WIFI_SYNC → IDLE（关）

**约束：**
- 录音期间不能开 WiFi
- WiFi 活动期间不能开始录音

**自动关闭：** WiFi AP 在 3 分钟后自动关闭（`CONFIG_CLIP_WIFI_TIMEOUT_MS`；0 禁用）—— 计时从 AP 启动或最后一个客户端断开起算；**已关联的客户端会保持 AP 开启**，即使空闲。

**错误情况：**
- `{"ok":false,"msg":"Missing argument (on/off)"}` / `"Invalid argument (use on/off)"`
- `"Cannot start WiFi in current state"` / `"Failed to start WiFi AP"` / `"Failed to stop WiFi AP"`

---

##### AT+USB - USB CDC+MSC 控制

启用或禁用 USB CDC（串口）与 MSC（大容量存储 / SD 卡访问）。

**请求（启用）：**
```
AT+USB=on
```

**请求（禁用）：**
```
AT+USB=off
```

**请求（查询）：**
```
AT+USB?
```

**响应（启用/禁用）：**
```json
{
  "ok": true,
  "data": {"status": "on"}
}
```

或

```json
{
  "ok": true,
  "data": {"status": "off"}
}
```

**自动禁用行为：**
- 拔线后 USB 自动禁用
- USB 启用但 10 分钟无电缆接入时自动禁用

---

##### AT+LOG - SD 日志后端控制

控制 SD 卡日志后端（`/SD:/LOG`，滚动文件）。适用于无 UART 控制台的设备（如生产镜像)做事后调试。

**请求（设置）：**
```
AT+LOG=off
AT+LOG=info
AT+LOG=debug
```

**请求（查询）：**
```
AT+LOG?
```

**响应（设置）：**
```json
{
  "ok": true,
  "data": {"log": "info"}
}
```

**响应（查询）：**
```json
{
  "ok": true,
  "data": {"log": "off"}
}
```

**模式：**
| 模式 | 行为 |
|------|----------|
| `off` | 停用 FS 日志后端；SD 卡可回到空闲断电（最低待机电流） |
| `info` | 确保 SD 挂载，INF 级及以上日志写入 `/SD:/LOG` |
| `debug` | 同 info 但为 DBG 级（最详尽；排障用） |

**说明：**
- 开机默认随构建走：**debug** 镜像开机启用 `info`；**production** 镜像默认 `off`。`AT+LOG` 运行时覆盖。
- 启用后端（`info`/`debug`）会保持 SD 挂载，抬高待机电流 —— 诊断用完设回 `off` 恢复低功耗。
- 只要后端活动，查询一律报 `info`（无论 debug 级别）。

**错误情况：**
- 缺失或非法模式（必须 `off`/`info`/`debug`）
- 启用（`info`/`debug`）时 SD 卡不可用

---

##### AT+FORMAT - 格式化 SD 卡

用 FATFS 格式化 SD 卡。删除全部录音。

**请求：**
```
AT+FORMAT
```

**响应：**
```json
{
  "ok": true
}
```

**错误情况：**
- SD 卡未挂载
- 录音期间不能格式化

---

##### AT+POWEROFF - 关机

关闭设备（进入 ship mode 超低功耗）。

**请求：**
```
AT+POWEROFF
```

**响应：**
```json
{
  "ok": true,
  "data": {"poweroff": "shutting down"}
}
```

**错误情况：**
- `{"ok":false,"msg":"USB power present — unplug USB first"}` —— 只要 VBUS 在场 PMIC 就拒绝 ship mode，即使电池已满（门控是 VBUS，不是 `charging` 标志）

**副作用：**
- 显示关机画面
- 先停止活动录音（先落盘文件）并取消传输
- 进入 PMIC ship mode（需物理按键唤醒）
- 未保存数据全部保留
- 若 ship mode 被拒绝，设备自动恢复 —— 状态栏恢复、按键重新启用、推送
  `{"event":"poweroff","status":"failed"}`；整个流程有 8 秒失败保护重启兜底

---

##### AT+PAIR - 蓝牙配对

管理 BLE 配对。

**请求（查询）：**
```
AT+PAIR?
```

**请求（重置）：**
```
AT+PAIR=reset
```

**响应（查询，已配对）：**
```json
{
  "ok": true,
  "msg": "\"paired\",\"addr\":\"AA:BB:CC:DD:EE:FF\""
}
```

**响应（查询，未配对）：**
```json
{
  "ok": true,
  "msg": "\"unpaired\""
}
```

> 注意：与其他查询命令不同，`AT+PAIR?` 的负载经 `"msg"` 字段返回（状态词及绑定时的对端地址以 JSON 片段形式嵌在 `msg` 内），不在 `"data"` 下。

**响应（重置）：**
```json
{
  "ok": true,
  "data": { "rebooting": true, "sd_erase": "pending" }
}
```

**取值：**
- "paired"：已绑定
- "unpaired"：未绑定

**重置副作用：**
- 清除 BLE 绑定信息（`ble_clear_bonds`）并**同步**保存 settings，确保删除在重启后生效
- 绑定清除 + settings 保存完成后**立即**应答；SD 卡擦除刻意推迟到后台（~500 ms），避免大量录音时客户端超时
- 后台**格式化 SD 卡** —— 销毁全部录音（解配隐私擦除）
- SD 擦除完成后重启设备
- 需要重新配对

> 应答（`"sd_erase":"pending"`）在擦除前发出；重启只在后台擦除完成后发生，因此设备保证以"未绑定 + 干净 SD"回来。

---

##### AT+FACTORY - 恢复出厂

将全部设置恢复出厂默认。

**请求：**
```
AT+FACTORY=confirm
```

**响应：**
```json
{
  "ok": true,
  "msg": "Factory reset complete, rebooting..."
}
```

**副作用：**
- 清除全部 NVS 配置
- 清除 BLE 配对
- 删除 SD 卡全部录音
- 重启设备

**错误情况：**
- `{"ok":false,"msg":"Add 'confirm' or 'yes' to proceed"}` / `"Factory reset failed"`

**警告：** 需要 "confirm" 参数防误触。

---

##### AT+REBOOT - 重启设备

**请求：**
```
AT+REBOOT
```

**响应：**
```json
{
  "ok": true,
  "data": { "reboot": "restarting" }
}
```

**副作用：**
- 终止当前录音（如有）
- 停止文件传输（如有）
- 重启设备

---

##### AT+DFU - 进入 DFU/恢复模式

写 boot-mode 保持寄存器并重启进 MCUboot 串口恢复（用于 USB/BLE 固件升级）。

**请求：**
```
AT+DFU
```

**响应：**
```json
{
  "ok": true,
  "data": { "dfu": "rebooting" }
}
```

**错误情况：**
- `{"ok":false,"msg":"Failed to set boot mode"}`

**副作用：**
- 向保持寄存器写 `BOOT_MODE_TYPE_BOOTLOADER`
- 重启进 MCUboot 串口恢复（响应后 ~500 ms）

---

##### AT+WIFICFG - WiFi 信道 / 法规域

配置 WiFi AP 信道与两字母法规域（下次 WiFi 启动生效）。合法信道：**1–13（2.4 GHz）或 36–165（5 GHz）**。

**请求（设置）：**
```
AT+WIFICFG=36:US
```

**请求（查询）：**
```
AT+WIFICFG?
```

**响应（设置）：**
```json
{
  "ok": true,
  "msg": "Saved (apply on next WiFi start)",
  "data": { "channel": 36, "reg_domain": "US" }
}
```

> 设置是唯一同时返回 `"msg"`（信息性）与 `"data"` 回显的命令。

**响应（查询）：**
```json
{
  "ok": true,
  "data": { "channel": 36, "reg_domain": "US" }
}
```

**错误情况：**
- `{"ok":false,"msg":"Missing argument (format: channel:CC)"}` / `"usage: channel:CC e.g. 36:US"`（无冒号 / 域非 2 字母）
- `"channel: 1-13 (2.4G) or 36-165 (5G)"`（非法信道）
- `"reg domain: 2-letter country"`（非字母）

> 小写法规域会被接受并自动转大写（`36:us` → `US`）。

---

## 4. 文件传输协议（BLE 二进制帧）

### 4.1 概述

文件传输使用文件数据特征值（`0x6E400004`）上的二进制帧协议。每个 BLE 通知携带一帧，以首字节（帧类型）标识。该协议与 WiFi UDP 传输共用（见附录 D），略有差异。

### 4.2 帧类型

| 类型 | Hex | 方向 | 说明 |
|------|-----|-----------|-------------|
| DATA | `0x01` | 设备→App | 文件数据块 |
| FILE_START | `0x10` | 设备→App | 文件传输开始 |
| FILE_END | `0x11` | 设备→App | 文件结束（全文件 CRC32） |
| TRANSFER_DONE | `0x12` | 设备→App | 全部文件完成 |
| STREAM_START | `0x13` | 设备→App | RTC 实时流开始（仅 BLE） |
| STREAM_DATA | `0x14` | 设备→App | RTC 实时 Opus 帧（仅 BLE） |
| STREAM_END | `0x15` | 设备→App | RTC 实时流结束（仅 BLE） |

**BLE 特有行为：**
- 无逐帧 CRC（BLE 链路层保证可靠送达）
- 无 FILE_ACK（无需重传）
- 无 HEARTBEAT（BLE 连接管理保活）
- `STREAM_*` 帧仅存在于 BLE（不支持 WiFi/UDP 上的 RTC）

### 4.3 帧格式

#### DATA 帧

带序号的文件数据块。

```
[type:1][seq_lo:1][seq_hi:1][len_lo:1][len_hi:1][payload:N]
```

| 偏移 | 大小 | 字段 | 说明 |
|--------|------|-------|-------------|
| 0 | 1 | type | `0x01` |
| 1 | 2 | seq | 序号（uint16 LE） |
| 3 | 2 | len | 负载长度（uint16 LE） |
| 5 | N | payload | 原始 Opus 数据 |

**头部长度：** 5 字节
**最大负载：** MTU - 3 - 5（MTU 247 时为 239 字节）

#### FILE_START 帧

标志一个文件传输的开始。

```
[type:1][fn_len:1][filename:fn_len][file_size:4]
```

| 偏移 | 大小 | 字段 | 说明 |
|--------|------|-------|-------------|
| 0 | 1 | type | `0x10` |
| 1 | 1 | fn_len | 文件名长度 |
| 2 | N | filename | UTF-8 文件名（如 `"0015.opus"`） |
| 2+N | 4 | file_size | 文件总字节（uint32 LE） |

#### FILE_END 帧

标志当前文件结束，附全文件 CRC32 供完整性校验。

```
[type:1][crc32:4]
```

| 偏移 | 大小 | 字段 | 说明 |
|--------|------|-------|-------------|
| 0 | 1 | type | `0x11` |
| 1 | 4 | crc32 | 全文件数据的 IEEE CRC32（uint32 LE） |

CRC32 对全部 DATA 帧负载串接计算（即完整文件数据）。多项式 0xEDB88320（同 zlib.crc32，初值 0xFFFFFFFF）。

#### TRANSFER_DONE 帧

全会话文件传输完成。

```
[type:1][sid_len:1][session_id:sid_len][file_count:4]
```

| 偏移 | 大小 | 字段 | 说明 |
|--------|------|-------|-------------|
| 0 | 1 | type | `0x12` |
| 1 | 1 | sid_len | 会话 ID 长度 |
| 2 | N | session_id | 会话 ID 字符串（如 `"20260326120000"`） |
| 2+N | 4 | file_count | 传输文件总数（uint32 LE） |

#### STREAM_START 帧

RTC 实时流开始（对 RTC 会话执行 `AT+DOWNLOAD` 后发送一次）。

```
[type:1][sid_len:1][session_id:sid_len]
```

| 偏移 | 大小 | 字段 | 说明 |
|--------|------|-------|-------------|
| 0 | 1 | type | `0x13` |
| 1 | 1 | sid_len | 会话 ID 长度 |
| 2 | N | session_id | 会话 ID 字符串 |

#### STREAM_DATA 帧

一个实时 Opus 帧（20 ms 音频）。与 DATA 帧布局相同但序号空间独立。按采集顺序发出；设备受 BLE 背压时**丢帧而不阻塞**。注意 `seq` 只在帧成功交给 BLE 链路后前进，被丢的帧**不消耗**序号：丢帧表现为缺帧，而不是 `seq` 跳变。接收端仍应把 `seq` 不连续当协议漂移指示（防御性），而非设备侧丢包计数。

```
[type:1][seq_lo:1][seq_hi:1][len_lo:1][len_hi:1][payload:N]
```

| 偏移 | 大小 | 字段 | 说明 |
|--------|------|-------|-------------|
| 0 | 1 | type | `0x14` |
| 1 | 2 | seq | 流序号（uint16 LE，从 0 起） |
| 3 | 2 | len | 负载长度（uint16 LE） |
| 5 | N | payload | 一个 Opus 包 |

#### STREAM_END 帧

RTC 流结束。

```
[type:1][reason:1]
```

| 偏移 | 大小 | 字段 | 说明 |
|--------|------|-------|-------------|
| 0 | 1 | type | `0x15` |
| 1 | 1 | reason | `0`=AT+STOP 停止，`1`=启动超时，`2`=BLE 断连 |

### 4.4 传输流程

```
App                              Device
 │                                  │
 │─ AT+DOWNLOAD=20260326120000 ───>│
 │<─ {"ok":true} ──────────────────│
 │                                  │
 │  会话内每个文件：
 │                                  │
 │<─ FILE_START("0001.opus", 2400)─│
 │<─ DATA(seq=0, len=239, ...) ────│
 │<─ DATA(seq=1, len=239, ...) ────│
 │<─ ...                          │
 │<─ DATA(seq=9, len=183, ...) ────│  末块（<239）
 │<─ FILE_END(crc32=0xA1B2C3D4) ──│
 │                                  │
 │<─ FILE_START("0002.opus", 2400)─│
 │<─ DATA(seq=0, ...) ─────────────│
 │<─ ...                          │
 │<─ FILE_END(crc32=...) ──────────│
 │                                  │
 │<─ TRANSFER_DONE("20260326120000", 30)│
```

**要点：**
- 一个会话的全部帧在同一文件数据特征值上发送
- 传输期间 AT 命令响应继续在响应特征值上到达
- 设备可在文件传输并发处理 AT 命令（如 `AT+GSTAT`）

### 4.5 流控

文件传输在后台运行。传输期间可发 AT 命令：

**传输期间支持：**
- `AT+GSTAT` — 查询状态（返回 "TRANSMITTING" 状态及 `state`、`session`、`total`、`bytes` 字段）
- `AT+CANCEL` — 取消传输（线程安全：在传输线程处理）

> `AT+PAUSE`/`AT+RESUME` 只作用于**录音**，不作用于传输 —— 没有暂停的传输状态。传输控制只有 `AT+CANCEL` 与经 `AT+DOWNLOAD=session:file` 的续传（4.6 节）。

**示例：**
```
App: AT+DOWNLOAD=20260326120000
Device: {"ok":true}
Device: <FILE_START 帧>
Device: <DATA 帧...>
App: AT+GSTAT  (非阻塞！)
Device: {"ok":true,"data":{"state":"TRANSMITTING",...}}
Device: <DATA 帧继续...>
Device: <FILE_END 帧>
Device: <TRANSFER_DONE 帧>
```

### 4.6 从文件续传

续传部分完成的会话用冒号语法：

```
AT+DOWNLOAD=<session_id>:<start_file>
```

**续传逻辑：**
1. 客户端查询会话详情：`AT+LIST=<session_id>`
2. 响应含 `synced` 计数（如已传 15 个文件）
3. 客户端算下一文件：`synced + 1` → `0016.opus`
4. 客户端发送：`AT+DOWNLOAD=<session_id>:0016.opus`
5. 设备从 0016.opus 起传输

**示例：**
```
# 查询 synced 计数
AT+LIST=20260326120000
→ {"ok":true,"data":{"synced":15,"files":30,...}}

# 从 0016.opus 续传
AT+DOWNLOAD=20260326120000:0016.opus
→ {"ok":true}
```

### 4.7 连续同步（实时）

设备正在录音时，客户端可启动一个持续到录音结束的传输，实现录音期间实时下载。

**流程：**
1. 开始录音：`AT+START=enhanced`
2. 立即开始下载：`AT+DOWNLOAD=<session_id>`
3. 设备边写 SD 边流式发送文件（连续模式：传输跟随新文件直到录音停止）
4. 录音停止（`AT+STOP`）后设备发送 `TRANSFER_DONE`
5. 客户端确知全部文件已收

**工具用法：**
- `record.py` — 录音期间实时同步
- `clip-web.py` — 录音开始时的后台同步任务

### 4.8 RTC 实时流

RTC 模式经 BLE 实时流式传输麦克风音频，不在 SD 卡写任何内容。它以低延迟优先于完整性：设备只保留一个小的有界编码帧队列，消费端缺席或太慢时丢弃最旧帧。

**前置条件：** BLE 已连接**且**文件数据特征值 CCCD 已订阅（notify 开启），然后才 `AT+START=RTC`。

**流程：**
1. 客户端连接并订阅文件数据通知
2. `AT+START=RTC` → 响应带会话 ID，麦克风管线启动（设备状态广播 `"STREAMING"`）。帧立即编码但只进缓冲（有界、丢最旧）
3. `AT+DOWNLOAD=<session_id>` → 设备**丢弃**此前排队的全部数据（RTC 只交付"现在" —— DOWNLOAD 之前的音频永不发送），发送 `STREAM_START`，之后实时发送 `STREAM_DATA`
4. `AT+STOP` → `STREAM_END`（reason 0），会话拆卸

**暂停/恢复：** `AT+PAUSE` 丢弃全部缓冲数据并停止发送（麦克风管线继续跑）；`AT+RESUME` 从当前帧继续。RTC 模式拒绝 `AT+MARK`。

**自动拆卸：** `AT+START=RTC` 后 5 秒内未收到 `AT+DOWNLOAD`（事件 `rtc`/`timeout`），或 BLE 断连时立即，会话自行中止。

**说明：**
- RTC 会话从不出现在 `AT+LIST`（无存储）
- 实时流与文件传输共用文件数据特征值，二者互斥（流式期间不能跑文件下载）
- 流期间重发 `AT+DOWNLOAD=<rtc_session>` 是幂等的（答 ok、流继续）—— 与文件传输同一条规则
- 背压策略：丢帧计数、从不重试。因 `seq` 只在成功发送后前进，丢帧表现为缺帧（当前固件与可靠 BLE 链路下不应出现序号不连续；出现即按协议漂移对待）

## 5. 状态机

### 5.1 设备状态机

**状态：**
- **UNINITIALIZED**：启动中、硬件初始化
- **IDLE**：可录音、可传输、可开 WiFi
- **RECORDING**：正在录音
- **TRANSMITTING**：正在传输文件
- **WIFI_SYNC**：WiFi AP 活动，可文件传输
- **PAUSED**：录音暂停
- **ERROR**：错误状态，需干预
- **OTA**：为固件上传流程定义，但上传期间从不进入（DFU 活动由独立标志跟踪）；上传运行时按键输入被忽略

**约束：**
- 录音期间不能开 WiFi（RECORDING → WIFI_SYNC 无效）
- WiFi 活动期间不能开始录音（WIFI_SYNC → RECORDING 无效）
- 只有 IDLE 可进入 RECORDING 或 WIFI_SYNC

### 5.2 录音状态机

**迁移：**
- IDLE → RECORDING：`AT+START`（SD 或 RTC）或按键长按松开（仅 SD —— RTC 只能 AT）
- RECORDING → IDLE：长按按键 或 `AT+STOP`

**录音专属动作：**
- RECORDING 期间短按：添加书签

### 5.3 传输状态机

**迁移：**
- IDLE → TRANSMITTING：`AT+DOWNLOAD`
- TRANSMITTING → IDLE：`AT+CANCEL` 或传输完成或超时或传输通道断开（自动取消）

> **没有暂停的传输状态**。`AT+PAUSE`/`AT+RESUME` 只作用于录音（3.3.5 节）。传输中途通道断开时设备取消传输回到 IDLE；客户端用 `AT+DOWNLOAD=<session_id>:<next_file>` 续传（4.6 节）。

### 5.4 连接状态机

**状态：**
- **DISCONNECTED**：未连接，广播中
- **CONNECTING**：连接进行中
- **CONNECTED**：已连接未配对
- **PAIRING**：配对进行中
- **BONDED**：已连接并绑定（加密）

## 6. 数据格式

### 6.1 卡上录音布局

录音使用固定 FAT32 布局：

```
/SD:/REC/YYYYMMDD/HH/MM/SS/
  session.json
  marks.bin
  0/0001.opus
```

`YYYYMMDDHHMMSS` 即 `AT+LIST`、`AT+DOWNLOAD`、`AT+DELETE` 暴露的会话 ID；`SS` 是其最后两位。分段文件放在编号的组目录里，每组最多 `CONFIG_CLIP_STORAGE_FILES_PER_GROUP` 个文件。旧的 `/SD:/REC/<session_id>/` 布局不受支持。

### 6.2 会话元数据（session.json）

存于每个会话目录，包含会话信息、同步进度与音频格式。

**创建**：录音开始时（创建会话）
**更新**：录音停止时（时长、文件数）与每次传输结束（synced 计数）

```json
{
  "id": "20240203100000",
  "duration": 600,
  "files": 30,
  "synced": 15,
  "channels": 2,
  "sample_rate": 16000,
  "mode": "normal"
}
```

**字段：**
- `id`：会话 ID（时间戳格式：YYYYMMDDHHMMSS，14 位）
- `duration`：录音秒数（录音中为 0）
- `files`：会话音频文件总数（录音中为 0）
- `synced`：已成功传输的文件数
- `channels`：声道数（1=单声道，2=立体声）
- `sample_rate`：采样率 Hz（如 16000）
- `mode`：录音模式（"normal" 或 "enhanced"）

**用途：**
- 跟踪传输进度支持续传
- 存音频格式供正确解码/播放
- 支持已传输文件清理
- 支持断连/重连场景

### 6.3 书签数据（marks.bin）

高效书签存储的二进制格式。

**头（6 字节）：**
```
[4 字节 magic: "BMRK"]
[2 字节 count: uint16_t]
```

**条目（每条 4 字节，共 `count` 条）：**
```
[4 字节 offset: uint32 - 距会话开始的秒数]
```

只存 offset —— 没有时间戳、文件索引或备注字段。

### 6.4 书签 JSON（bookmarks.json）

同步后导出、供前端可视化的 JSON 格式。

**文件位置：** `recordings/{session_id}/bookmarks.json`

```json
[
  {"offset": 30},
  {"offset": 60},
  {"offset": 90}
]
```

**每条字段：**
- `offset`：距会话开始的秒数（用于合并音频中的定位）

> 书签只存 offset —— 没有备注文本。

### 6.5 Opus 帧格式

每个 Opus 文件是帧序列：

```
[2 字节长度][Opus 帧数据][2 字节长度][Opus 帧数据]...
```

- **长度**：uint16，小端
- **帧数据**：原始 Opus 编码字节
- **帧长**：通常 20ms @ 16kHz = 320 采样

> **播放提示：** 录制的 `NNNN.opus` 是这种原始长度前缀 Opus 容器 —— **不是** Ogg Opus 或 WebM。标准播放器无法直接播放。用参考工具转换：`applications/clip/tests/clip/codec.py`（`convert_to_ogg_opus()`，把原始帧包成合法 Ogg Opus）或 `applications/clip/tests/tools/decode_opus.py`（直接解码为 WAV）。解码参数（采样率、声道数）来自会话的 `session.json`（`sample_rate`、`channels` 字段，6.2 节）。

### 6.6 传输标记

**没有** `.transferred` 标记文件。传输进度以 `synced` 文件计数持久化在会话的 `session.json` 里（6.2 节，每次成功传输后更新，存于 `/SD:/REC/YYYYMMDD/HH/MM/SS/session.json`）。

**用途：**
- 标记已成功传输的文件数（续传点）
- 供自动删除策略与未传输会话指示使用

## 7. 通知与事件

### 7.1 主动通知

设备经响应特征值对重要事件发送主动通知。

#### 7.1.1 录音状态变化

录音状态变化（开始、停止、暂停、恢复）时发送。用 `"event":"state"` 与 AT 命令响应区分。

```json
{"event":"state","state":"RECORDING","session":"20240203100000"}
```

**触发：** 持久录音由 `AT+START` 或按键长按松开开始；RTC 流由 `AT+START=rtc` 开始（仅 AT）。

```json
{"event":"state","state":"IDLE","session":"20240203100000","duration":600}
```

**触发：** 录音停止（AT+STOP 或长按）。`duration` 单位秒。

```json
{"event":"state","state":"PAUSED","session":"20240203100000"}
```

**触发：** 录音暂停（AT+PAUSE）

```json
{"event":"state","state":"RECORDING","session":"20240203100000"}
```

**触发：** 录音恢复（AT+RESUME）

**字段：**
- `event`：状态变化事件恒为 `"state"`
- `state`：新状态 —— `"RECORDING"`、`"IDLE"`、`"PAUSED"`
- `session`：会话 ID
- `duration`：录音秒数（仅在停止/IDLE 时出现）

**说明：**
- 在响应发送特征值上发送（与 AT 响应同通道）
- 以 `"event"` 字段区分于 AT 响应
- BLE 未连接或通知未开启时不发送
- AT 命令与按键事件都会触发

#### 7.1.2 书签事件

录音期间添加书签时发送。

```json
{"event":"mark","session":"20240203100000","mark_count":3}
```

**触发：** 添加书签（AT+MARK 或短按按键）

**字段：**
- `event`：书签事件恒为 `"mark"`
- `session`：会话 ID
- `mark_count`：本次书签后会话书签总数

#### 7.1.3 连接 / WiFi / USB / 存储 / RTC / 关机事件

其他状态变化事件用通用两字段形式 `{"event":"<name>","status":"<status>"}`（由 `ble_notify_event` 构造）：

| `event` | `status` | 触发 |
|---------|----------|---------|
| `ble` | `connected` / `disconnected` | 中央设备连接 / 断开 |
| `wifi` | `on` / `off` | WiFi AP 启动 / 停止（手动或自动关闭） |
| `usb` | `on` / `off` | USB CDC 启用 / 禁用（插拔、10 分钟自动关、或 `AT+USB`） |
| `storage` | `full` | SD 卡越过存储满阈值；录音被拒 |
| `rtc` | `timeout` | RTC 会话中止 —— 启动超时内无 `AT+DOWNLOAD`（4.8 节） |
| `poweroff` | `failed` | 关机被拒（ship mode 拒绝）；设备已恢复 |

这是 `ble_notify_event` 来源的完整清单。

示例：
```json
{"event":"usb","status":"on"}
```

> 以 `"event"` 字段是否存在区分通知与 AT 响应。没有通用的 `battery_low` / `storage_low` / `error` 推送；低电量只在 OLED 上显示。

### 7.2 音频可视化数据

实时音频能量数据经音频可视化特征值（`0x6E400005`）发送，不是 JSON 事件。格式见 2.2.4 节。

### 7.3 BLE 事件通知

连接、WiFi、USB、存储事件见 7.1.3 —— 全部使用通用 `{"event":"<name>","status":"<value>"}` 形式（如 `{"event":"ble","status":"connected"}`）在响应发送特征值上发送。

**客户端处理：** 在响应发送特征值收到 JSON 时检查 `"event"` 键。存在即为事件通知而非命令响应。

## 8. 错误处理

### 8.1 错误响应格式

每个错误都是带 `"ok": false` 与人类可读 `"msg"` 字符串的 JSON 对象。**没有数字错误码** —— 处理器只返回消息。

```json
{
  "ok": false,
  "msg": "Human-readable error message"
}
```

### 8.2 常见错误消息

这些消息字符串跨命令出现（处理器原文）：

| 消息 | 常见原因 |
|---------|---------------|
| `SD card not mounted` | 存储命令运行时 SD 不在 / 未挂载 |
| `Failed to list sessions` | 枚举会话时 SD I/O 错误 |
| `Session not found` | 未知会话 ID |
| `cannot delete active session` | 对活动会话 `AT+DELETE` |
| `Invalid session ID` | ID 格式错误 |
| `Already recording or invalid state` | 录音中 `AT+START` |
| `No active session` / `Not recording` | 无录音时 `AT+STOP`/`AT+MARK`/`AT+PAUSE` |
| `Not paused` | 未暂停时 `AT+RESUME` |
| `Transfer already in progress` | 传输活动期间对不同会话/通道 `AT+DOWNLOAD` —— 立即返回；重发同一会话+同一通道则答 ok 并继续 |
| `No active transfer` | 无传输时 `AT+CANCEL` |
| `Mode must be normal or enhanced` | `AT+MODE` 值非法 |
| `Brightness must be 0-255` | `AT+BRIGHTNESS` 超范围 |
| `Auto-delete must be 0-30 days or off` | `AT+AUTODEL` 值非法 |
| `Log mode must be off, info or debug` | `AT+LOG` 值非法 |
| `Cannot format while recording` | 录音中 `AT+FORMAT` |
| `Recording in progress, stop first` | 录音活动阻塞 `AT+USB`/`AT+WIFI` |
| `Cannot start WiFi in current state` | 录音/传输中 `AT+WIFI=on` |

### 8.3 恢复

- **存储错误**（`SD card not mounted`、列表/格式化失败）：重新插拔或更换 SD 卡；SD 栈在下次访问时惰性重挂载
- **状态错误**（`Already recording`、`Transfer already in progress`）：先停当前操作（`AT+STOP` / `AT+CANCEL`）
- **持续/卡死状态**：`AT+REBOOT`，或长按按键关机进 ship mode 后重新上电

## 9. 时序与约束

### 9.1 命令超时

| 操作 | 超时 |
|-----------|---------|
| 命令处理 | 5 秒 |
| 文件打开 | 2 秒 |
| 录音启动 | 3 秒 |
| 恢复出厂 | 10 秒 |
| 重启 | 5 秒 |

### 9.2 传输超时

| 操作 | 超时 |
|-----------|---------|
| 传输启动 | 10 秒 |
| 块间 | 30 秒 |
| 总传输时长 | 1 小时 |

### 9.3 限速

防止 BLE 拥塞：
- **每秒最大命令数**：10
- **通知最小间隔**：20ms

### 9.4 缓冲区

| 缓冲 | 大小 |
|--------|------|
| 命令缓冲 | 512 字节 |
| 响应缓冲 | 512 字节 |
| 文件块缓冲 | 4096 字节（Kconfig 编译期） |
| 音频缓冲 | 32KB |
| SD 卡缓冲 | 4KB |

## 10. 安全考量

### 10.1 鉴权

**LE Secure Connections（强制）**
- 使用椭圆曲线 Diffie-Hellman（ECDH）
- 关联方式为 **Just Works**（设备无 passkey 显示 / 数字比较的输入输出能力；设备自动确认配对）
- 因此配对未鉴权 —— 配对过程本身*不*提供 MITM 防护；假定配对时的物理邻近

### 10.2 加密

**AES-128 CCM（强制）**
- 全部 BLE 流量加密
- 密钥由配对过程派生
- 绑定设备保存密钥用于重连

### 10.3 授权

**单绑定策略**
- 设备只保存一个中央设备的绑定
- 新配对清除旧绑定
- `AT+PAIR=reset` 手动清绑定（同时格式化 SD 卡以保护隐私，然后重启）

## 11. 命令序列

### 11.1 典型录音工作流

```
1. 连接：App 发现设备、连接、配对
2. 查状态：AT+GSTAT
3. 设模式：AT+MODE=enhanced
4. 开始录音：AT+START
5. [可选] 加书签：AT+MARK=Important point
6. 停止录音：AT+STOP
7. [稍后] 同步会话（见 11.2）
```

### 11.2 完整同步工作流

```
1. 列会话：AT+LIST
2. 每个会话：
   a. 会话信息：AT+LIST=<session>  （含 synced 计数、音频格式）
   b. 书签：AT+MARKS=<session>
   c. 下载：AT+DOWNLOAD=<session>
   d. 接收二进制帧（每文件 FILE_START → DATA → FILE_END）
   e. 接收 TRANSFER_DONE 帧
   f. 用 FILE_END 帧校验文件 CRC32
3. 可选删除会话：AT+DELETE=<session>
```

### 11.3 错误恢复序列

**传输失败恢复：**
```
1. 检测错误（断连或超时）
2. 断连时设备自动取消传输
3. 等待重连（自动重连）
4. 查询会话：AT+LIST=<session_id>（取 synced 计数）
5. 从下一文件续传：AT+DOWNLOAD=<session_id>:<next_file>
```

**SD 卡错误恢复：**
```
1. 检测错误：{"ok":false,"msg":"SD card not mounted"}
2. 停止当前操作
3. 重插 SD 卡
4. 等待检测
5. 重试操作
```

## 12. 设计说明

- 新命令只增不改（旧 App 忽略未知事件）
- 响应可添加可选字段
- 码率与复杂度按模式固定（构建期 Kconfig），运行时不可单独配置
- 传输块大小为编译期（`CONFIG_CLIP_TRANSFER_CHUNK_SIZE`）
- 不支持 AGC（SpeexDSP FIXED_POINT 构建限制）

## 附录 A：完整命令速查

| 命令 | 类型 | 用途 | 章节 |
|---------|------|---------|---------|
| AT+GSTAT | EXEC | 设备状态 | 3.3.1 |
| AT+TIME | GET/SET | 系统时间 | 3.3.1 |
| AT+VERSION | EXEC | 版本信息 | 3.3.1 |
| AT+BATT | EXEC | 电池状态（%、充电、mV、°C） | 3.3.1 |
| AT+STORAGE | EXEC/GET | SD 存储统计 | 3.3.1 |
| AT+DEVICE | EXEC/GET | 设备名 | 3.3.7 |
| AT+START | EXEC/SET | 开始录音（normal/enhanced/rtc） | 3.3.2 |
| AT+STOP | EXEC | 停止录音 | 3.3.2 |
| AT+MARK | EXEC/SET | 添加书签 | 3.3.2 |
| AT+LIST | GET/SET | 列出会话/文件 | 3.3.3 |
| AT+DELETE | SET | 删除会话 | 3.3.3 |
| AT+MARKS | GET/SET | 获取书签 | 3.3.3 |
| AT+DOWNLOAD | SET | 下载文件/实时流 | 3.3.4 |
| AT+PAUSE | EXEC | 暂停录音 | 3.3.5 |
| AT+RESUME | EXEC | 恢复录音 | 3.3.5 |
| AT+CANCEL | EXEC | 取消传输 | 3.3.5 |
| AT+AUTODEL | GET/SET | 自动删除策略 | 3.3.6 |
| AT+FORMAT | EXEC | 格式化 SD 卡 | 3.3.7 |
| AT+POWEROFF | EXEC | 关机 | 3.3.7 |
| AT+WIFI | EXEC/GET/SET | WiFi AP 控制 | 3.3.7 |
| AT+USB | GET/SET | USB CDC+MSC 控制 | 3.3.7 |
| AT+MODE | GET/SET | 录音模式 | 3.3.7 |
| AT+BRIGHTNESS | GET/SET | OLED 亮度 | 3.3.7 |
| AT+PAIR | GET/SET | BLE 配对 | 3.3.7 |
| AT+FACTORY | SET | 恢复出厂 | 3.3.7 |
| AT+REBOOT | EXEC | 重启 | 3.3.7 |
| AT+NAME | GET/SET | 用户设备名（≤256 字节） | 3.3.7 |
| AT+LOG | GET/SET | SD 日志后端（off/info/debug） | 3.3.7 |
| AT+DFU | EXEC | 重启进 MCUboot DFU/恢复 | 3.3.7 |
| AT+WIFICFG | GET/SET | WiFi 信道/法规域 | 3.3.7 |

## 附录 B：会话示例

### 会话 1：首次设置

```
App: AT+GSTAT
Device: {"ok":true,"data":{"state":"IDLE","battery":100,"charging":false,...}}

App: AT+TIME=1706918430
Device: {"ok":true}

App: AT+MODE=enhanced
Device: {"ok":true}
```

### 会话 2：录音与传输

```
App: AT+START
Device: {"ok":true,"data":{"session":"20240203100000",...}}
Device: {"event":"state","state":"RECORDING","session":"20240203100000"}

[录音进行中，音频可视化数据在特征值 0x6E400005 上流式发送...]

App: AT+MARK=Important point
Device: {"ok":true,"data":{"timestamp":1706918430,...}}
Device: {"event":"mark","session":"20240203100000","mark_count":1}

App: AT+STOP
Device: {"ok":true,"data":{"duration":600,...}}
Device: {"event":"state","state":"IDLE","session":"20240203100000","duration":600}

App: AT+LIST
Device: {"ok":true,"data":{"total":1,"sessions":[...]}}

App: AT+DOWNLOAD=20240203100000
Device: {"ok":true}
Device: <FILE_START "0001.opus" size=2400>
Device: <DATA seq=0 len=239 payload=...>
Device: <DATA seq=1 len=239 payload=...>
...
Device: <FILE_END crc32=0xA1B2C3D4>
Device: <FILE_START "0002.opus" size=2400>
Device: <DATA seq=0 ...>
...
Device: <FILE_END crc32=...>
Device: <TRANSFER_DONE "20240203100000" count=30>
```

## 附录 C：性能特征

### BLE 传输速率

| MTU | 吞吐 | 1MB 用时 |
|-----|------------|----------|
| 23 | ~8 KB/s | ~2m 5s |
| 247 | ~22 KB/s | ~46s |
| 517 | ~28 KB/s | ~36s |

**最优配置：** MTU 517

### WiFi UDP 传输速率

| 场景 | 吞吐 | 1MB 用时 |
|----------|------------|----------|
| 典型 WiFi | ~500 KB/s | ~2s |

### 内存占用

| 组件 | 占用 |
|-----------|-------|
| 音频缓冲 | 32 KB |
| Opus 编码器 | 20 KB |
| SpeexDSP | 10 KB |
| 传输缓冲 | 4 KB |
| BLE 协议栈 | ~50 KB |
| 固定合计 | ~116 KB |

**可用堆：** 非安全 SRAM 192 KB 中约 ~32 KB

## 附录 D：WiFi UDP 传输协议

WiFi AP 模式下提供高速本地文件传输。使用与 BLE 相同的二进制帧协议（第 4 节），另加可靠性与保活帧。

### D.1 WiFi AP 配置

| 参数 | 值 |
|-----------|-------|
| SSID | `ClipAP_XXXX`（芯片 ID 后 4 个十六进制位） |
| 密码 | 每台设备随机（8 字符，首次开机生成） |
| IP 地址 | `192.168.4.1` |
| UDP 端口 | `8089` |
| 协议 | UDP |

### D.2 帧类型

| 类型 | Hex | 方向 | 说明 |
|------|-----|-----------|-------------|
| DATA | `0x01` | 设备→客户端 | 文件数据（带逐帧 CRC32） |
| FILE_ACK | `0x03` | 客户端→设备 | 文件校验结果 |
| FILE_START | `0x10` | 设备→客户端 | 文件传输开始 |
| FILE_END | `0x11` | 设备→客户端 | 文件结束（全文件 CRC32） |
| TRANSFER_DONE | `0x12` | 设备→客户端 | 全部文件完成 |
| AT_RESP | `0x20` | 设备→客户端 | AT 命令响应（JSON） |
| HEARTBEAT | `0x30` | 客户端→设备 | 保活（客户端发起） |

> RTC 实时流帧（`0x13`–`0x15`，4.3 节）仅限 BLE，未为 UDP 传输定义。

### D.3 BLE 与 WiFi UDP 对比

| | BLE | WiFi UDP |
|---|---|---|
| AT 命令 | BLE Write 特征值 | UDP 明文 `"AT+XXX\n"` |
| AT 响应 | BLE Notify（JSON） | UDP AT_RESP 帧（`0x20`） |
| DATA 头部 | 5 字节 | 9 字节（+4 CRC32） |
| 逐帧 CRC | 无（链路层） | 每帧 IEEE CRC32 |
| FILE_ACK | 无 | 有（CRC 不符 → 重传） |
| 心跳 | 无 | 传输期 ~200 ms，空闲超时 30s |
| 吞吐 | ~15 KB/s | ~500 KB/s |

### D.4 帧格式（UDP 特有差异）

#### DATA 帧（UDP）

```
[type:1][seq_lo:1][seq_hi:1][len_lo:1][len_hi:1][crc32:4][payload:N]
```

| 偏移 | 大小 | 字段 | 说明 |
|--------|------|-------|-------------|
| 0 | 1 | type | `0x01` |
| 1 | 2 | seq | 序号（uint16 LE，4096 回绕） |
| 3 | 2 | len | 负载长度（uint16 LE） |
| 5 | 4 | crc32 | 负载的 IEEE CRC32（uint32 LE） |
| 9 | N | payload | 原始 Opus 数据 |

**头部长度：** 9 字节（逐帧 CRC32 比 BLE 多 4 字节）
**最大负载：** 1024 字节

#### FILE_ACK 帧（客户端→设备）

**旧式 ACK（2 字节）：**
```
[type:1][result:1]
```

| 偏移 | 大小 | 字段 | 说明 |
|--------|------|-------|-------------|
| 0 | 1 | type | `0x03` |
| 1 | 1 | result | `0x00` = CRC 正确，`0x01` = CRC 不符 |

**选择性 NACK 形式（result = `0x01` 带位图）：**
```
[type:1][result:1][total_seqs:2][missing_bitmap:N]
```

| 偏移 | 大小 | 字段 | 说明 |
|--------|------|-------|-------------|
| 0 | 1 | type | `0x03` |
| 1 | 1 | result | `0x01`（CRC 不符） |
| 2 | 2 | total_seqs | 文件的 DATA 序号总数（uint16 LE） |
| 4 | N | missing_bitmap | 缺失序号位图：位 `i` 置位 = 序号 `i` 未收到（LSB 在前，每 8 个序号 1 字节） |

客户端在收到 FILE_END 后发送。带位图时设备只重传缺失的 DATA 帧（选择性修复）；无位图（旧式 2 字节或空位图）时重传整个文件（最多 3 次重试）。

#### AT_RESP 帧

```
[type:1][len_lo:1][len_hi:1][json_data:N]
```

| 偏移 | 大小 | 字段 | 说明 |
|--------|------|-------|-------------|
| 0 | 1 | type | `0x20` |
| 1 | 2 | len | JSON 响应长度（uint16 LE） |
| 3 | N | json_data | JSON 响应文本 |

#### HEARTBEAT 帧（客户端→设备保活）

```
[type:1][timestamp:4]
```

| 偏移 | 大小 | 字段 | 说明 |
|--------|------|-------|-------------|
| 0 | 1 | type | `0x30` |
| 1 | 4 | timestamp | 运行毫秒数（uint32 LE） |

**客户端间隔：** 活动传输期 ~200 ms（让手机 WiFi 射频不进省电）；空闲时作普通保活（参考客户端 ~5 s）
**超时：** UDP socket 30 秒无任何活动（任意帧都算）—— 设备丢弃连接（`CONFIG_CLIP_UDP_CONNECTION_TIMEOUT_MS`）
**注意：** 设备只接收心跳、从不发送。

### D.5 AT 命令格式（UDP）

AT 命令以明文经 UDP 发送（无二进制包装）：

```
AT+GSTAT\n
AT+LIST\n
AT+DOWNLOAD=20260326120000\n
```

结尾换行（`\n`）必需。

### D.6 共享帧格式

FILE_START、FILE_END、TRANSFER_DONE 帧与 BLE 相同（见 4.3 节）。

### D.7 传输流程（UDP）

```
客户端                            设备 (192.168.4.1:8089)
 │                                  │
 │─ AT+DOWNLOAD=20260326120000\n ─>│
 │<─ AT_RESP({"ok":true,...}) ─────│
 │                                  │
 │  每个文件：
 │<─ FILE_START("0001.opus", 2400)─│
 │<─ DATA(seq=0, len=1024, ...) ───│
 │<─ DATA(seq=1, len=1024, ...) ───│
 │<─ ...                          │
 │<─ FILE_END(crc32=0xA1B2C3D4) ──│
 │─ FILE_ACK(0x00) ──────────────>│  CRC 正确
 │                                  │
 │  （若 CRC 不符：）
 │<─ FILE_END(crc32=...) ──────────│  重传
 │─ FILE_ACK(0x01) ──────────────>│  CRC NACK
 │                                  │
 │<─ TRANSFER_DONE("20260326...", 30)│
```

## 附录 E：按键事件

设备单按键（GPIO1.15，低有效），多级按压检测。

### E.1 按键动作

| 动作 | 触发 | 行为 |
|--------|---------|----------|
| 单击 | 按下并释放（< 1s） | 按状态而定（见下） |
| 长按 | 按住 > 1s | 开始/停止录音，震动确认 |
| 长按 Level 1/2/3 | 继续按住 > 2s/3s/4s | 关机画面（松开取消） |
| 释放 | 按键释放 | 执行延迟动作或关机 |
| 双击 | 快按两下 | 保留（无动作） |

### E.2 单击行为

| 当前状态 | 动作 |
|---------------|--------|
| RECORDING | 添加书签 |
| PAUSED | 添加书签 |
| IDLE | 显示状态栏（限时） |
| WIFI_SYNC | 显示状态栏（限时） |
| ERROR | 显示状态栏（限时） |

### E.3 长按行为

**录音中：**
1. 按住 1s → 立即停止录音 + 震动
2. 继续按住 → 进入关机流程

**空闲 / 错误 / WiFi 同步：**
1. 按住 1s → 震动确认阈值
2. 继续按住 → 进入关机流程
3. 关机级别之前松开 → 开始录音

**充电中：** 关机被阻断，长按级别被忽略（门控为 VBUS 在场）。

### E.4 关机流程

1. 长按达到 Level 1（> 2s）→ 显示关机画面
2. 用户松开 → 设备进入 ship mode（超低功耗）
3. Level 1 之前松开 → 动作取消，不关机

### E.5 状态变化通知

改变状态的按键动作发送主动通知：

| 动作 | 通知 |
|--------|-------------|
| 开始录音 | `{"event":"state","state":"RECORDING",...}` |
| 停止录音 | `{"event":"state","state":"IDLE",...}` |
| 添加书签 | `{"event":"mark","session":"...","mark_count":N}` |

## 附录 F：扩展协议 —— 新增 AT 命令

向固件添加新命令的可复制流程。示例：假想的 `AT+PING` 返回 `{"ok":true,"data":{"pong":true}}`。

全部命令注册在 `applications/clip/src/at_commands.c` 的 `at_commands_register()` 里。没有数组 —— 每条命令是一个 `static const struct at_command`，逐个用 `at_server_register_cmd()` 注册。

**处理器签名**（`applications/clip/include/at_server.h`）：

```c
typedef int (*at_cmd_handler_t)(struct at_cmd_ctx *ctx, char *response, size_t len);
```

- `ctx->name` / `ctx->type` / `ctx->args` 携带解析后的命令（args 是 `=` 后的原始字符串，或 NULL）。
- 处理器把 JSON 响应（含结尾 `\n`）写入 `response` 并返回写入字节数；失败返回 `AT_ERR_*` 码（如 `AT_ERR_PARAM`、`AT_ERR_NOMEM`）—— 服务器随后自行发送错误 JSON。

**1. 写处理器**（`at_commands_register()` 之上任意位置）：

```c
/* PING - 连通性测试 */
static int cmd_ping_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    int n = snprintf(response, len, "{\"ok\":true,\"data\":{\"pong\":true}}");
    if (n < 0 || n >= len - 2) {
        return AT_ERR_NOMEM;
    }
    response[n] = '\n';
    return n + 1;
}
```

带 `"msg"` 或动态 `"data"` 的响应优先用现成辅助函数
`create_json_response(bool success, const char *message, const char *data_json, char *response, size_t len)`
（构造 `{"ok":true|false}` 加可选 `,"msg":"..."` 与 `,"data":<raw json>` —— `data_json` 传渲染好的 JSON 片段字符串）。

**2. 注册**（`at_commands_register()` 内）：

```c
    /* PING - 连通性测试 */
    static const struct at_command ping_cmd = {
        .name = "PING",
        .flags = AT_CMD_EXEC,
        .handler = cmd_ping_handler,
    };
    err = at_server_register_cmd(&ping_cmd);
    if (err) return err;
```

`struct at_command` 字段顺序：`name`、`flags`（`AT_CMD_SET`、`AT_CMD_QUERY`、`AT_CMD_EXEC`，见 `at_server.h`）、`handler`。

**3. 编译、烧录、测试：**

```sh
west build --build-dir build-clip --board clip/nrf5340/cpuapp applications/clip
west flash --build-dir build-clip && nrfutil device reset   # 本板 --reset 不生效
python applications/clip/tests/tools/ble_terminal.py        # 然后输入 PING 或 AT+PING
```

`ble_terminal.py` 在输入不以 `AT+` 开头时自动补前缀，`PING` 与 `AT+PING` 等价。同一命令也适用于 UDP（`udp_terminal.py`）与 USB CDC —— 三条通道汇入同一 AT 服务器。

**4. 在本文件记录** —— 同一个 PR 里在 3.3.x 下加完整命令章节，并在附录 A 速查表加一行。

## 附录 G：面向客户端开发者的 BLE OTA

供移动 App 实现应用内固件升级。

**传输。** 运行中的应用经 BLE 暴露标准 mcumgr SMP 服务（`applications/clip/prj.conf` 中 `CONFIG_NCS_SAMPLE_MCUMGR_BT_OTA_DFU=y`，其选中 Zephyr 的 `MCUMGR_TRANSPORT_BT`）：

- 服务 UUID：`8D53DC1D-1DB7-4CD3-868B-8A527460AA84`
- 特征值（write + notify）：`DA2E7828-FBCE-4E01-AE9E-261174997C48`

在该特征值上说标准 mcumgr/SMP（CBOR 编码的镜像管理组）—— 与 `mcumgr` / `newtmgr` 客户端同一协议。

**无需重启进 bootloader。** 镜像上传到次槽，应用保持运行。设备为双镜像（`CONFIG_MCUMGR_GRP_IMG_UPDATABLE_IMAGE_NUMBER=2`）：镜像 0 = 应用核，镜像 1 = 网络核。

**切换语义 —— 重要。** 本板 MCUboot 运行在 **overwrite-only 模式**（`MCUBOOT_MODE_OVERWRITE_ONLY` 为板级默认，见 `boards/seeed/clip/Kconfig.sysbuild`）。即：

- **没有 image-test / image-confirm / 自动回滚**。经典 mcumgr "先 test 后 confirm" 流程不适用。
- 上传完成后发 mcumgr reset（OS 组）—— 重启后 MCUboot 用新镜像覆盖主槽并**立即无条件**启动。坏镜像无法回滚。

**上传哪个产物：**

- `clip-<ver>-ota.zip`（sysbuild 的 `dfu_application.zip`）—— 含应用核**与**网络核的多镜像包。首选。
- `clip-<ver>-signed.bin` —— 仅应用核镜像。

两者都附在每个 GitHub Release 上。主机侧流程（mcumgr CLI、nRF Connect、USB 串口 DFU 兜底）见 [`docs/usb_dfu.md`](usb_dfu.md)。
