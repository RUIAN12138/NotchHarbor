# Notch Harbor

Notch Harbor 是 macOS 刘海面板，集成媒体与同步歌词、文件架与 AirDrop、剪贴板、Agent 会话、日历与天气。它从 [Boring Notch](https://github.com/TheBoredTeam/boring.notch) 派生，延续原项目的 GPL-3.0 许可。第三方组件的归属见 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES) 和 [THIRD_PARTY](THIRD_PARTY)。

## 构建

需安装 Xcode（含 Metal 工具链）、Node.js 和 npm。首次构建会从 Swift Package Manager 和 npm 拉取锁定版本的依赖。

```sh
./scripts/build-local.sh
```

输出为 `.build/xcode/Build/Products/Release/Notch Harbor.app`。脚本从本仓库的 Folia 源文件生成歌词视图，并随 App 一并打包许可。构建产物、依赖缓存和 Node 模块都在 `.build/` 下。脚本默认临时签名，可用 `NOTCH_HARBOR_SIGNING_IDENTITY` 指定本地签名身份。

`NotchHarbor.xcodeproj` 可直接用 Xcode 打开查看和调试。完整出包使用上面的脚本，包含 Folia 预处理与资源打包。构建过程与系统正式安装路径独立。

## 目录

- `boringNotch/` 主应用、设置、业务组件、Metal 和资源。
- `BoringNotchXPCHelper/` 应用的 XPC 辅助服务。
- `mediaremote-adapter/` 正在使用的媒体控制桥与运行时探测。
- `THIRD_PARTY/` 参与构建的 Folia 源文件和开源致谢。
- `scripts/` 构建、可选 Agent 集成及回归测试。Agent 接入来源见 [说明](docs/ACTIVITY_SOURCES.md)。

项目保留既有 Bundle ID、XPC 标识和数据目录标识，以便以后替换安装时继续识别已有数据和授权。文件夹独立不改变用户环境中此前已注册的 Agent 监听器或服务路径。

## 回归检查

```sh
python3 scripts/test-music-spectrum.py
python3 scripts/test-lyrics-selection.py
python3 scripts/test-optical-surface.py
python3 scripts/test-agent-interaction.py
python3 scripts/test-drop-target.py
```
