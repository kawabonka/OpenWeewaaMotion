# WeeWaa Motion

原生 macOS 双手六轴工具，使用 SwiftUI + CoreBluetooth。无需 Python 环境即可运行。

应用：`/path/to/OpenWeewaaMotion/dist/WeeWaa Motion.app`

## 使用

1. 让两个手柄开机，退出 iPad 原厂 App，释放蓝牙连接。
2. 打开 WeeWaa Motion，点“连接两只手柄”。首次使用按系统提示允许蓝牙访问。
3. 在“实时仪表”查看每只手柄的三轴加速度、三轴角速度、原始计数、波形、电量、采样率和姿态预览。
4. “演示模式”生成模拟数据并断开真实手柄；模拟数据不会发到 DSU 或 JSON。
5. 在“传感器校准”分别选择左 / 右手，依次完成下列校准。

每个手柄的仪表卡片新增“震动测试”按钮，发送已由用户在左右手确认的原厂短脉冲 `82 50 96 96`。

## 校准

### 静置

将手柄放在固定表面，采集 3 秒。程序检查方差并计算陀螺仪的三轴零偏。移动过大时拒绝保存。本机两只手柄均已实测完成此步骤，重启 App 后保留。

### 六面

依次选择 X+、X−、Y+、Y−、Z+、Z−。缓慢翻转手柄，使目标原始加速度轴的绝对值最大，正负号与目标匹配，另两轴接近零。静止后点击“采集此朝向”。

每个朝向采集 3 秒；程序检查稳定度和主轴方向。六个朝向收齐后，用各轴正 / 负面平均值计算零偏和 count/g。六面进度只在当前 App 会话保留，完成后的参数永久保存。

### 已知转角

选 GX、GY 或 GZ，以及 90° 或 180°。点“开始转角”，沿该原始传感器轴单方向旋转准确角度，停稳后点“结束转角”。使用桌面直角等参考，不要转回起点。程序对去零偏后的计数按采样间隔积分，得到 count/(°/s)。

其他轴的净积分超过目标轴的 45%、采样不足、旋转量不足或超时会拒绝结果。手工角度的准确性决定比例准确性，请一次只绕一条轴转动。GX、GY、GZ 各完成一次。

可以选择原始轴到输出轴的排列，以及 X / Y 的反向；Z 的符号按右手坐标系计算。输出 X 对应俯仰旋转、Y 对应横滚旋转、Z 对应偏航旋转。实际游戏如方向不符，可在此调整。

校准按左右手独立存放在 App 的本机 UserDefaults 中。未校准比例为加速度 2048 count/g、角速度 16.4 count/(°/s) 的暂定值，界面标记“估算”；不能将它们视作已验证量程。

## 输出

### DSU / Cemuhook

在“体感输出”开启 DSU。服务器仅绑定 `127.0.0.1:26760`，同一 Mac 上的模拟器可作为 DSU 客户端订阅：

- 槽位 0：左手。
- 槽位 1：右手。
- 发送加速度（g）、角速度（°/s）及单调时间戳（微秒）。
- 按键、摇杆和触摸保持中立；不是完整游戏手柄模拟。
- 完成静置、六面、三个转角校准后，对应槽位才报告可用并输出真实数据。
- 正在校准、断连或数据停止时暂停该槽位输出。订阅超时为 5 秒，客户端须续订。
- 数据包内 MAC 为本程序的稳定槽位标识，不是手柄真实蓝牙地址。

支持协议版本查询、控制器信息查询、按槽位 / MAC / 全部订阅、CRC32 和 100 字节运动包。已用独立 Python 客户端验证两个槽位的数据布局和收发；尚未与具体模拟器或 nxnative 做端到端游戏测试。DSU 属于应用层体感接口，系统不会因此把硬件识别成 Switch / Xbox / PS 手柄。nxnative 是否可直接接入，取决于它是否支持 DSU 或相应适配层。

协议参考：[Cemuhook protocol](https://v1993.github.io/cemuhook-protocol/)。

### JSON UDP

在“体感输出”开启 JSON，每个真实有效样本发送一个对象到 `127.0.0.1:8765`：

```json
{
  "hand": "left",
  "device": "设备 UUID",
  "timestamp_us": 123456789,
  "raw_axes": [0, 0, 2048, 0, 0, 0],
  "accel_g": [0, 0, 1],
  "gyro_dps": [0, 0, 0],
  "calibrated": false
}
```

`calibrated: false` 时仅原始计数可直接使用，物理单位是估算。姿态预览使用简化互补滤波；六轴传感器不能提供绝对航向，航向会漂移，回中可重置显示参考。DSU 发送传感器矢量，不依赖姿态预览。

## 游戏震动回传与 nxnative

在“体感输出”开启“接收游戏震动”，App 会在 `127.0.0.1:8766` 接收 `{"type":"rumble","hand":"left","intensity":1.0}`。大于 0.05 触发一次固定原厂效果，每手最多每秒 4 次；0 不触发新效果，已有短脉冲自行停止。未验证各指令字节的强度 / 时长含义，因此当前不提供精确强度、频率或 HD Rumble。

已准备 nxnative 源码双向接入补丁，可将 JSON 六轴送入游戏，并把游戏左右马达的状态回传到本 App。详见 [nxnative 接入说明](../nxnative_integration/README.md)。模块和 UDP 测试通过，尚未完成具体游戏构建及游戏内实测。

## 构建与验证

```sh
cd /path/to/OpenWeewaaMotion
bash NativeApp/build.sh
xcrun swiftc -swift-version 5 -module-cache-path .build/ModuleCache \
  NativeApp/Sources/Motion.swift NativeApp/Sources/Output.swift \
  NativeApp/Tests/main.swift -o .build/MotionSelfTests -framework Combine
.build/MotionSelfTests
```

构建使用本机 Command Line Tools，不需要下载第三方依赖。App 为本机架构，最低部署目标 macOS 14，使用本机临时签名，尚未做 Developer ID 公证或跨机器分发测试。

已验证：历史左右手共 4,161 个真实数据包；DSU CRC/长度/字段；校准换算、六面求解、静置移动拒绝、已知转角比例及混轴拒绝；原生 App 同时连接左右手约 83 Hz；两只真实手柄的静置校准、保存与重启加载。独立客户端收到了标准 DSU 双槽位测试数据；原生 App 真实 JSON 在两秒内收到左手 167 包、右手 166 包，且未完成完整校准的两个 DSU 槽位正确暂停。

源代码：

- `Sources/Motion.swift`：数据解码、校准、互补滤波。
- `Sources/Bluetooth.swift`：双手连接、原厂启动序列、保活、演示模式。
- `Sources/Output.swift`：DSU 与 JSON UDP。
- `Sources/App.swift`：原生界面。
- `Tests/main.swift`：真实记录回放与协议 / 校准测试。
