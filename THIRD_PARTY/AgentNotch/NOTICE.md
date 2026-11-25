# Agent Notch reuse

Source: Agent Notch (derived from Vibe Notch / Claude Island).
License: Apache-2.0; original LICENSE and UPSTREAM_NOTICE retained.

Adapted: session-row presentation and local Codex token_count.rate_limits parsing from Services/Usage/UsageLimitMonitor.swift, UI/Components/UsageLimitBar.swift and UI/Views/ClaudeInstancesView.swift.

Modifications: Boring Notch glass row styling, disclosure-only session detail, credential-free read-only bridge transport, bounded/cached numeric usage snapshots, malformed-input and expiry validation. Tool-name and visible-message parsing are adapted from Services/Session/ConversationParser.swift. The bridge exports no messages, tool arguments or results. Conversation text is read locally inside the app after the user authorizes the logs folder. No original approval channel or user hooks are modified.

Task-list sizing and rows, processing spinner, and conversation header / text layout are adapted from Agent Notch’s SessionRowPresentation, ClaudeInstancesView, ProcessingSpinner and ChatView.

Agent Notch’s ChatView and Services/Chat/AgentTransport.swift informed replies from the notch and exact session targeting. Boring Notch routes an open Codex session to its desktop owner using the local owner/follower protocol, with the owner-discovery and start/steer request formats documented by codex-web (https://github.com/i-am-BT/codex-web/blob/main/desktop-ipc-client.mjs) and by Codex issue #54591. Sessions without a desktop owner can use the app-server transport when idle. Boring Notch adds model-generated suggestions and a same-signature XPC bridge. The original app sandbox and Agent hooks are retained.
