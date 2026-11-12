# OpenWeewaaMotion

原生 macOS WeeWaa 双手六轴与震动工具：SwiftUI、CoreBluetooth、校准、DSU、JSON UDP 和 nxnative 接入补丁。

```sh
bash NativeApp/build.sh
```

构建后打开 `dist/WeeWaa Motion.app`。

仓库仅包含去除设备标识与时间信息的运动解码测试样本，不包含原始蓝牙抓包或已编译 App。文档中的本机实测记录文件名用于说明证据来源，原始记录未公开。

# WeeWaa → Mac 原始体感桥接

总体实施路线、当前验证状态和游戏接入验收标准，见 [WeeWaa 体感与震动接入 nxnative 实施方案](docs/WeeWaa体感与震动接入nxnative实施方案.md)。

## 原生工具 App

已制作 **WeeWaa Motion**：`dist/WeeWaa Motion.app`。支持双手实时六轴仪表、姿态演示、独立校准、DSU 标准输出和本机 JSON UDP。无需运行 Python。

详见 [App 使用说明](NativeApp/README.md)。左右手已在原生 App 同时连接实测，约 83 Hz；静置零偏已校准，完整量程仍需按界面完成六面及转角步骤。下文保留原始 Python 采集工具与协议调查记录。

震动已在左右手实测确认，App 已增加震动测试与本机游戏震动回传。另见 [nxnative 双向接入补丁与验证范围](nxnative_integration/README.md)。

已在这台 Mac 分别实测左右手柄成功：直接连接手柄，发送从原厂 iPad App 抓到的初始化指令，收到连续六通道原始数据。可将数据保存为 JSONL，或通过本机 UDP 交给自己的程序。

目前尚未实现模拟器 DSU 协议、物理单位校准或姿态融合。UDP 输出是本项目的 JSON 格式，不是模拟器可直接识别的 DSU。

## 运行

已安装的项目虚拟环境位于 `.venv`，依赖 Bleak 3.1.0。

先退出 iPad 原厂 App、释放右手柄连接，让右手柄开机。运行：

```sh
cd /path/to/OpenWeewaaMotion
.venv/bin/python capture_ble.py --start-stream --seconds 60 --output right-motion.jsonl
```

左手柄同样运行，增加 `--hand left`：

```sh
.venv/bin/python capture_ble.py --hand left --start-stream --seconds 60 --output left-motion.jsonl
```

`--hand` 默认是 `right`；`--device UUID` 可覆盖选择。左手也必须先从 iPad 断开连接。

`--start-stream` 会向 AE01 写入下文的实测初始化序列；不带此参数时仅订阅通知。每次使用不同输出文件名，已有文件不会被覆盖。Ctrl-C 或到时结束会取消通知并断开连接。

给自己的程序提供实时输入时，先在一个终端运行示例接收端：

```sh
.venv/bin/python receive_motion.py
```

在另一个终端运行：

```sh
.venv/bin/python capture_ble.py --start-stream --seconds 3600 --udp-port 8765 --output right-live.jsonl
```

接收左手时改为：

```sh
.venv/bin/python capture_ble.py --hand left --start-stream --seconds 3600 --udp-port 8765 --output left-live.jsonl
```

只向 `127.0.0.1:8765` 发送。JSON 含设备标识 `device`、左右手标识 `hand`（`left`/`right`）、`utc`、`elapsed_s`、`counter`、`raw_axes`、`axes` 和 `valid`。`axes` 把原始值 -32768 标记为 null，初始化最初几包出现该值；这只是当前的无效值处理约定。六个通道仍使用原始计数，不能当作 g、度/秒或欧拉角。

首次使用其他终端或应用可能需要授予蓝牙权限。若脚本在受限执行环境中报告 Bluetooth unsupported，应从具备蓝牙访问权限的普通 Mac 终端运行。本次已在获准访问蓝牙的执行环境中完成实测。

## 已验证的设备与协议

- 右手名称：`MRR_Boxing_Right`。
- 此 Mac 的右手 CoreBluetooth 标识：`FAA399E8-4DCE-2FA2-5791-37DC6DC43DC0`。它不是蓝牙 MAC 地址，换 Mac 需要重新发现设备。
- 左手名称：`MRR_Boxing_Left`，此 Mac 标识：`36DD541D-4D8C-3E12-3333-A75D12A06B3C`。
- 服务：`0000ae30-0000-1000-8000-00805f9b34fb`。
- 写指令：AE01，Write without Response。
- 接收：AE02，Notify。
- 已观察的原厂初始化：先订阅 AE02，约 0.9 秒后依次发送下表。

| AE01 数据（hex） | 发送后等待 | 已知情况 |
| --- | --- | --- |
| `29` | 约 240 ms | 用途未确定 |
| `60` | 约 400 ms | 收到以 60 开头的四字节回复 |
| `60` | 约 380 ms | 再次收到四字节回复 |
| `46` | 约 1 秒 | 用途未确定 |
| `12 64 FF 19 04 50 01 03 05 07 00` | 开始采集 | 发送后出现连续 19 字节通知；字段含义未解明 |
| `19` | 首次约 2 秒后，随后每 3 秒 | 原厂周期指令；可能是保活，含义未独立验证 |

只发送 29/60/60/46 时，Mac 收到查询回复但没有连续体感包。补齐 12... 指令后，Mac 成功收到连续数据。程序未写 OTA 服务，未刷固件。

## 19 字节运动包

| 偏移（从 0 起） | 长度 | 当前解释 |
| --- | --- | --- |
| 0 | 3 | 固定前缀 `11 06 00` |
| 3 | 4 | 小端无符号计数；通常每包增加 12 |
| 7 | 6 | 三个小端有符号 16 位原始通道 |
| 13 | 6 | 另三个小端有符号 16 位原始通道 |

前组三通道的静止表现符合加速度候选，后组三通道符合角速度候选；还需通过定向静置与已知角度旋转验证。计数步长结合约 83 Hz 的频率与毫秒时间戳相符，但设备时间单位尚未独立验证。

## 实测记录

- `weewaa-ipad-session-20261112.pklg`：原厂 iPad 通信原始记录，已停止并保存。
- `ipad-motion.jsonl`：从该记录提取的 ATT 写入、通知及运动字段。左手 5,782 包，右手 5,062 包；本次没有跳过分片或异常 ACL 包。
- `mac-right-first.jsonl`：仅前四条启动指令的对照实验；两个查询回复，无运动包。
- `mac-right-stream.jsonl`：完整初始化的 Mac 直连验证；1,663 个运动包，其中 1,661 包六通道均非 -32768，约 83.25 Hz；计数步长通常为 12，两次为 24。
- `mac-right-udp-check.jsonl`：本机 UDP 输出的硬件集成验证记录。
- `mac-left-stream.jsonl`：左手 Mac 直连验证；2,498 个运动包，其中 2,495 包六通道均非 -32768，约 83.31 Hz；计数步长通常为 12，一次为 24。静放、转动和挥动已实测。
- `mac-left-udp-check.jsonl`：左手本机 UDP 输出的硬件集成验证记录，消息标记 `hand: left`。

解析原厂记录：

```sh
.venv/bin/python extract_capture.py weewaa-ipad-session-20261112.pklg extracted-new.jsonl
```

`extract_capture.py` 适配本次小端 PacketLogger 文件，只提取完整、未分片的 ATT 数据包。遇到分片会计数并跳过，不会把片段误作完整运动包。连接句柄只在本次会话内有效，脚本从设备名称响应识别左右手。

## 下一步

1. 六面静置校准前三通道的方向、偏置和量程。
2. 每次只绕一个轴旋转已知角度，验证后三通道的方向、零偏和角速度比例。
3. 自己的程序可先使用原始通道；需要标准物理单位时应用校准结果。
4. 对指定模拟器实现它支持的运动输入接口，例如 DSU，并验证坐标系与时间戳；不保证任意游戏都能识别体感。

左右手均已分别通过 Python 工具的 Mac 直连和本机 UDP 验证。后续制作的原生 WeeWaa Motion App 已完成双手同时连接及双手 JSON 输出验证，详见上方 App 说明。

## 工具来源

- [Bleak macOS 后端与权限](https://bleak.readthedocs.io/en/develop/backends/macos.html)
- [Apple PacketLogger 工具入口](https://developer.apple.com/bluetooth/)
- [Apple 蓝牙日志描述文件与说明](https://developer.apple.com/feedback-assistant/profiles-and-logs/?name=bluetooth)

iPad 已安装 Apple 蓝牙日志描述文件并重启。抓包已完成，可在 iPad“设置 → 通用 → VPN 与设备管理”移除该描述文件，并按苹果说明重启以停止详细诊断日志。
