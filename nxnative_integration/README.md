# WeeWaa 体感与震动接入 nxnative（Mac）

已准备可审查的源码接入补丁，固定于 nxnative 官方提交：

`0c078130f6db7d0d32c1dc28146feaf97713f008`

## 已确认的震动指令

向服务 AE30 下的 AE01，以 Write without Response 写入：

```text
82 50 96 96
```

它来自原厂 iPad 训练抓包：左手出现 11 次，右手出现 1 次。已在右手直接回放，并通过本机 UDP → 原生 App → 蓝牙路径在左手回放，用户分别确认短暂震动后自动停止。

目前只验证这个固定效果。82 后各字节分别是强度、频率还是时长，尚未确定；没有将 50 / 96 猜作对应物理参数，也没有尝试 OTA 或固件写入。不能据此宣称支持可调强度、双频或 Switch HD Rumble。

原生 App 每只手柄已有“震动测试”按钮。在“体感输出”打开“接收游戏震动”后，向 `127.0.0.1:8766` 发送：

```json
{"type":"rumble","hand":"left","intensity":1.0}
```

`hand` 可以为 `left` / `right`，`intensity` 范围 0..1。当前大于 0.05 时触发固定脉冲，同一手柄最多每秒 4 次；0 不再触发，已触发的脉冲自行停止。此版本不把 intensity 线性映射到马达强度。演示模式和对应手柄正在校准时不会触发。

## 接入结构

```text
WeeWaa 左右手柄
   │ BLE AE02 六轴
   ▼
WeeWaa Motion App：校准、轴映射
   │ JSON UDP → 127.0.0.1:8765
   ▼
nxnative Mac 主机内的 weewaa_bridge.h
   ├─ dm_motion_set_joy：左右手各自的传感器
   └─ dm_motion_set_hid：普通 Pro 风格游戏的传感器

游戏 nn::hid 震动
   ▼
nxnative hle_haptics → haptics_apple 的自定义 sink
   │ JSON UDP → 127.0.0.1:8766
   ▼
WeeWaa Motion App → AE01 原厂震动脉冲
```

nxnative 当前源码已有 `dm_motion_set_hid`、`dm_motion_set_joy` 和 `dm_haptics_apple_set_sink`。本适配器使用这些现有接口，不通过虚拟 Sony / Switch 手柄伪装接入。现有 App 的 DSU 接口仍可供支持 DSU 的模拟器使用；本 nxnative 补丁走双向 JSON。

## 补丁范围

- 新增 `dm/host/weewaa_bridge.h`，不需要新增链接库或修改 Makefile 的源文件列表。
- 在 Mac 前端初始化震动模块后启动桥接。
- 为选定玩家暂停其他 GameController / Pro HID 的体感发布，保留它们的普通按键输入，避免多个体感源竞争。
- 游戏失去 / 获得焦点时暂停 / 恢复此体感源；震动的焦点暂停与增益 / 下限沿用 nxnative 原有处理。
- 默认玩家 1。普通单传感器游戏优先用右手，右手不在时使用左手。左右原始体感仍各自送入 Joy-Con 传感器入口。
- `DM_WEEWAA_JOYPAIR=1` 可声明一对 Joy-Con，但配对风格、左右独立读取和各游戏兼容性尚未进行游戏实测。
- 不增加 WeeWaa 按键 / 摇杆解码；游戏按键使用键盘或另一只标准手柄。
- 不和同一玩家的 Switch 2 自定义手柄路由混用，该路由也会设置自定义震动 sink。

## 单位、时间与校准

桥接只接受 `calibrated: true` 的 App 数据。加速度将 App 的 specific force 取负，转换为 nxnative 要求的重力方向向量（平放时应为 0,0,-1 g）；角速度从 °/s 转成 rad/s，XYZ 保持 Switch 右 / 前 / 上坐标系。实际握持方向用 App 的轴映射校准，需要在目标游戏里核对。

App 时间戳用于每手排序和去重。送入 nxnative 的时间戳采用 nxnative 自身 `now_ns()` 的接收时刻，不假定两个进程的时钟纪元相同；因此不会保留传输前的精确采样时刻。超过 500 ms 没有数据会清除该手的体感源。断连、暂停或未完成校准都不会作为新物理样本注入。

游戏马达 0 / 1 分别对应左 / 右手。持续振动状态以最多约 4 Hz 的有限脉冲近似；每个脉冲仍是原厂固定效果，频率与幅度不会忠实还原。收到静音后不再重复触发；最后一个脉冲的尾部不能用尚未验证的停止命令强行截断。

## 应用到自己的 nxnative 源码

先检查，不写入：

```sh
python3 /path/to/OpenWeewaaMotion/nxnative_integration/apply_patch.py /你的/nxnative源码目录
```

确认源码匹配后应用：

```sh
python3 /path/to/OpenWeewaaMotion/nxnative_integration/apply_patch.py /你的/nxnative源码目录 --apply
```

脚本检查 Mac 前端的 SHA-256，只接受已验证的基线；其他 nxnative 版本应先重新对齐补丁。另提供标准补丁 `nxnative-weewaa.patch`，可用 `git apply --check` 审查。两种方式选一种，不要重复应用。

然后使用你原有的 nxnative Mac 游戏构建 / 打包流程，重新编译主机并打包 `.app`。主机手工构建形式为 `make -C dm/host GAME=<游戏标题ID> dmhost`，但已有 Mac App 打包流程可能使用游戏构建目录下的另一份主机，需确保打入的是包含本补丁的新主机。本补丁未修改任何现成游戏 App，也未重新处理游戏资源或密钥。

运行新构建时设置环境变量（可使用原有环境配置方式）：

```text
DM_WEEWAA=1
DM_WEEWAA_PLAYER=1
DM_RUMBLE=1
DM_RUMBLE_LOG=1
DM_MOTION_LOG=1
```

`DM_WEEWAA_PLAYER` 为 1..8，建议先从玩家 1 与键盘输入验证。`DM_WEEWAA_JOYPAIR=1` 为可选实验项，不默认启用。

运行 WeeWaa Motion App，连接两手并完成六面 / 三轴转角校准，在“体感输出”同时开启“实时 JSON”和“接收游戏震动”。不要让其他程序占用本机 8765 / 8766 端口。

## 已完成的验证与剩余工作

已完成：

- 震动：两手真实硬件、用户触觉确认；左手包含 UDP 回传到 App 的整条链路。
- 补丁：在固定版本 Mac 前端副本上 `git apply --check` 和应用脚本检查通过。
- 适配器：对照该版本真实 nxnative API 头文件编译通过。
- 输入：校准标记、左右路由、右手优先、乱序 / 重复拒绝、单位转换、焦点暂停测试通过。
- 双向 UDP：测试主机实际接收模拟六轴，返回左右马达的强度及零值停止信号，18 条回传消息验证通过。
- App：本机接口监听成功，真实左手短震回传成功。

尚未完成：完整 nxnative 主机 / 游戏 App 的构建、真实游戏体感方向与动作判定、Joy-Con 配对模式、游戏内震动时序 / 长时间效果。当前工作目录没有可用的完整 nxnative checkout 或对应游戏构建资料，不能把上述模块测试说成游戏测试成功。还需要你实际使用的源码版本与游戏构建目录才能继续。

## 测试文件

`tests/bridge_test.m` 使用 nxnative 真实声明与测试桩，验证适配器本身，不能替代完整主机链接和游戏实测。源码参考保存在工作目录 `.research/nxnative`，仅下载了分析所需文件，不是完整可构建的仓库。

官方参考：

- [固定版本 dm_input.h](https://github.com/seedds/nxnative/blob/0c078130f6db7d0d32c1dc28146feaf97713f008/dm/host/dm_input.h)
- [固定版本自定义震动 sink](https://github.com/seedds/nxnative/blob/0c078130f6db7d0d32c1dc28146feaf97713f008/dm/host/haptics_apple.h)
- [Mac 构建与震动诊断](https://github.com/seedds/nxnative/blob/0c078130f6db7d0d32c1dc28146feaf97713f008/docs/development.md)

补丁上下文涉及的 nxnative 源码使用 MIT 许可，见同目录 `UPSTREAM_LICENSE`。
