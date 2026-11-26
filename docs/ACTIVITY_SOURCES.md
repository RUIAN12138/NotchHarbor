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

Notch Harbor先显示提醒，并在 Agent 页的对应会话保留待审批标记。点「查看并审批」可核对普通命令或完整文件补丁及其工作目录，再选择「仅允许这次」或「拒绝」。网络授权、需要选择权限范围的请求和其他无法完整呈现的审批可以交回 Codex。未处理的请求约 55 秒后回到 Codex 的默认流程。Notch Harbor未确认收到请求时，钩子最多等 3 秒。Notch Harbor不会修改 Codex 的审批策略或钩子信任设置。

Notch Harbor通过 Codex App Server 接续闲置的 CLI 会话时，沿用 Codex 的审批设置。App Server 为这个回合发出的命令、文件补丁及可完整列出的本轮读写路径或联网权限会直接出现在灵动岛。批复交给同一条实时连接，90 秒无操作即取消。如果 Codex 只提供取消作为拒绝选项，按钮显示「拒绝并取消」。补丁变更后旧请求失效。会话级授权、通配路径、特定网络端点等无法完整呈现的请求需要在 Codex 原会话重新发起。协议参考 [Codex Island 的 App Server 请求解析](https://github.com/Jarcis-cy/codex-island-app/blob/main/apps/macos/CodexIsland/Services/Remote/RemoteAppServerServerRequestParser.swift) 和 [Codex App Server 审批文档](https://learn.chatgpt.com/docs/app-server#approvals)。

### 桌面版与其他 Agent

- **Codex 桌面版**支持在「设置 → Hooks」审查同一个钩子。当前桌面会话触发已信任的 Hook 时，Notch Harbor可回传人工决定。桌面已经在原客户端显示的审批，则从当前运行实例的本地通知日志读取待办和结束事件，在 Agent 页优先显示。重启 Notch Harbor 时会从近期日志恢复仍待处理的请求；旧请求在收到原会话回复或超出一日恢复窗口时移除。可从弹窗和 Agent 页打开对应的原会话处理。日志不含可独立回传决定的连接。
- **Claude Code**运行 `python3 scripts/install-antigravity-hook.py --provider claude` 安装被动观察钩子。收到 `PermissionRequest` 时通知，权限被拒绝、工具结束或会话结束时清除。原有审批工具继续处理批复。
- **Gemini CLI**运行 `python3 scripts/install-antigravity-hook.py --provider gemini` 接入 `Notification / ToolPermission`，在工具或会话结束时清除。批复在原终端完成。
- **Antigravity、豆包 CLI 及其他接入方**可用现有 MCP 状态工具显式上报审批和清除。未发现可复用的 Antigravity 或豆包原会话审批通知接口时，普通工具启动不会被当作待审批。

### 在灵动岛内批复

桌面原生审批可能只显示在 Codex 原窗口中。可在「设置 → Agent → 打开系统授权设置」检查系统访问权限。Notch Harbor 会寻找 Codex 窗口中带有明确一次性允许和拒绝按钮的审批卡片。用户点击灵动岛按钮后，应用会重新核对原卡片，再把决定交回去。桌面日志用于核对回执。未能确认已送出的决定时，可打开 Codex 查看原卡片。模糊、已失效、未完整显示或多张同时可见的卡片仍需在 Codex 中处理。

弹窗和 Agent 详情展示原命令、文件差异或权限范围及工作目录。两个界面共用请求编号，重复点击只提交一次。App Server 返回该请求的确认后才显示已收到回执，本地钩子则在输出批复后给出回执。Hook 还可选择「交回原会话」，桌面原生请求可直接跳到对应会话。

Claude Code 的被动审批提醒可以继续使用。若希望由Notch Harbor直接处理 Claude Code 的 Bash 审批，可执行 `python3 scripts/install-codex-approval-hook.py --provider claude`，再从新会话开始测试。同一代理请只使用一个等待用户批复的钩子。安装器只追加Notch Harbor的钩子，先备份现有配置。

Codex 审批钩子会先检查原会话当前回合的 `approvals_reviewer`，只有明确交给用户的审批才交给Notch Harbor。自动审核和无法确认审批人的请求继续由 Codex 处理。参考 [Agent HUD 的审批判定](https://github.com/jazzenchen/agent-hud-open/blob/main/docs/client-hooks.md)。[codex-web 的桌面回传](https://github.com/i-am-BT/codex-web/blob/main/desktop-ipc-client.mjs)需可用的 Desktop IPC；本机桌面版的连接不可用，Notch Harbor不从日志回写授权。

### Codex 桌面回复

Notch Harbor优先在原桌面会话的实时连接上请求插入当前回合。只有原会话明确回复当前没有运行中的回合，才开启新回合。连接不可用时，调用 Codex 桌面版自带的 `codex queue`，让 CLI 查找共享 App Server，并核对队列回执里的原会话 UUID。消息入队后显示「已在 Codex 原会话排队」，由原桌面会话接收。当前回合正在运行时，通常要等回合结束。没有明确回执时保留原文，不自动重发。参考 [Codex CLI 队列](https://github.com/openai/codex/blob/main/codex-rs/tui/src/session_queue_commands.rs) 与 [AgentBridge 的回执校验](https://github.com/firejune/AgentBridge/blob/main/skill/agent-bridge/scripts/codex_queue.py)。
