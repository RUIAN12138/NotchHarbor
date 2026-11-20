# 活动来源与可选 Agent 接入

Notch Harbor 的活动汇总由主应用的 `UnifiedActivities.swift` 和设备模块维护。活动本身只作为界面状态；会话读取、快捷回复与授权各有独立路径。

- **Agent 状态**由本地通知和 `~/.multiagent-notch/session-state` 的状态快照补充。可选的 `scripts/install-activity-bridge.py` 注册用户级 LaunchAgent，启动项目内的 `activity-bridge.py`。监听器用所在项目的绝对路径，已有监听器会继续使用其注册时的位置。
- **Gemini / Antigravity** 的可选钩子安装器为 `scripts/install-antigravity-hook.py`。只有安装接入时才需要运行，应用构建本身不会改写 Agent 配置。
- **耳机状态**使用 Core Audio 输出变化与 CoreBluetooth 开盖广播。Shima 的本地系统动画解析和 apple-ble 的广播结构归属详见 `THIRD_PARTY/`。系统耳机素材由运行中的 macOS 提供，无需从其他工作区拷贝。
- **媒体**从应用支持的播放器接收元数据，通用系统媒体入口依赖仓库内的 MediaRemoteAdapter。Folia 歌词组件使用项目锁定的源文件构建。

如需停用可选的状态监听器，可从终端执行 `launchctl bootout gui/$(id -u)/local.boringnotch.activity-bridge`。已安装的 Agent 钩子与监听器各自管理。
