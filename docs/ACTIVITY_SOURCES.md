# 活动来源与可选 Agent 接入

Notch Harbor 的活动汇总由主应用的 `UnifiedActivities.swift` 和设备模块维护。活动本身只作为界面状态；会话读取、快捷回复与授权各有独立路径。

- **Agent 状态**由本地通知和 `~/.multiagent-notch/session-state` 的状态快照补充。可选的 `scripts/install-activity-bridge.py` 注册用户级 LaunchAgent，启动项目内的 `activity-bridge.py`。监听器用所在项目的绝对路径，已有监听器会继续使用其注册时的位置。
- **Gemini / Antigravity** 的可选钩子安装器为 `scripts/install-antigravity-hook.py`。只有安装接入时才需要运行，应用构建本身不会改写 Agent 配置。
- **耳机状态**使用 Core Audio 输出变化与 CoreBluetooth 开盖广播。Shima 的本地系统动画解析和 apple-ble 的广播结构归属详见 `THIRD_PARTY/`。系统耳机素材由运行中的 macOS 提供，无需从其他工作区拷贝。
- **媒体**从应用支持的播放器接收元数据，通用系统媒体入口依赖仓库内的 MediaRemoteAdapter。Folia 歌词组件使用项目锁定的源文件构建。

如需停用可选的状态监听器，可从终端执行 `launchctl bootout gui/$(id -u)/local.boringnotch.activity-bridge`。已安装的 Agent 钩子与监听器各自管理。

## MCP 接入

用支持 stdio MCP 的 Agent 将 `/usr/bin/python3` 作为命令，并把当前仓库中 `scripts/notch-harbor-mcp.py` 的绝对路径作为唯一参数。状态由现有的用户级 Activity Bridge 送入 Notch Harbor。

- `notch_harbor_status` 检查应用和本地监听器。
- `set_agent_activity` 使用稳定的 `source`、`session_id` 和 `phase` 更新会话条。状态包括 `working`、`question`、`approval`、`completed`、`failed` 和 `clear`。标题可选，最多 80 个字符。
- `set_doubao_activity` 同样接收 `phase`，可传真实数字会话 ID 关联豆包 CLI 的会话。通用 MCP 状态不读取 Agent 的聊天记录。通知中的审批状态只负责提示。

Agent 列表保留进行中与待处理会话，每个来源另显示最多两条 15 分钟内更新过的非活跃会话。列表名额单独计算，因此第三条新会话可以挤出旧列表项，但已打开的旧会话详情仍能读到，直到其最近一次活动满 15 分钟。到期自动移出列表，Agent 原始聊天记录保留。审批提示依据实时上报，在批复、会话停止或请求到期后消失。应用启动等待新状态，避免复活缓存里的旧审批。豆包的最近会话由内置 CLI 查询提供。展开会话时用本机豆包 CLI 的 `--export` 读正文。应用在内存中复用近期导出和分页结果；主动发送时用 `--resume` 并核对返回的会话 ID。CLI 登录由豆包管理。

接入方可以通过 `set_doubao_activity` 上报 `phase: "approval"`，可附带 `request_id` 和一条简短的 `action`。同一请求继续使用相同 ID，新请求换新 ID。请求在豆包原终端处理后，上报 `working` 或 `clear`。豆包 CLI 的非交互命令没有提供能接收并批复原终端待办的接口。

## Codex 审批

运行 `python3 scripts/install-codex-approval-hook.py` 注册独立的 `PermissionRequest` 钩子，然后在 Codex 的钩子审查界面信任 **Notch Harbor 审批**。CLI 可从 `/hooks` 进入审查。已有钩子保留。钩子的 JSON 字段和批复格式来自 [Codex Hooks 文档](https://learn.chatgpt.com/docs/hooks#permissionrequest)。

潮屿先显示提醒，并在 Agent 页的对应会话保留待审批标记。点「查看并审批」可核对普通命令及其工作目录，再选择「仅允许这次」或「拒绝」。网络授权、需要选择权限范围的请求和其他无法完整呈现的审批可以交回 Codex。未处理的请求约 55 秒后回到 Codex 的默认流程。潮屿未确认收到请求时，钩子最多等 3 秒。潮屿不会修改 Codex 的审批策略或钩子信任设置。
