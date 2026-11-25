"""Validate the production Foundation renderer with transcript and compact Markdown."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'boringNotch/components/Notch/UnifiedActivities.swift').read_text()
renderer = source[source.index('enum AgentMarkdownFormatting {'):source.index('private struct AgentUsageSummary:')]
checks = r'''
let message = """
# Findings

1. **Done** and `swift test`
2. [Docs](https://example.com) [Local](file:///tmp/test) [Blocked](javascript:alert)

> Notes

| Provider | Status |
| --- | --- |
| Codex | **Ready** |

```swift
let ready = true
```
"""
private let blocks = AgentMarkdownBlock.parse(message)
precondition(blocks.first?.heading == 1)
precondition(blocks.compactMap(\.marker) == ["1.", "2."])
precondition(blocks.contains(where: \.isQuote))
precondition(blocks.contains { $0.isCode && String($0.text.characters).contains("let ready = true") })
let table = blocks.first { !$0.tableRows.isEmpty }!.tableRows
precondition(table.map { $0.map { String($0.characters) } } == [["Provider", "Status"], ["Codex", "Ready"]])
precondition(table[1][1].runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
let links = blocks.flatMap { $0.text.runs.compactMap(\.link) }
precondition(links.map(\.absoluteString) == ["https://example.com"])
let compact = AgentMarkdownFormatting.inline("**Passed** · [Details](https://example.com)")
precondition(String(compact.characters) == "Passed · Details")
precondition(compact.runs.allSatisfy { $0.link == nil })
precondition(compact.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
precondition(String(AgentMarkdownFormatting.inline("普通文本").characters) == "普通文本")
print("PASS: shared transcript formatting, tables, safe links and button/summary Markdown")
'''
with tempfile.TemporaryDirectory(prefix='notch-agent-markdown-') as folder:
    main = Path(folder) / 'main.swift'
    executable = Path(folder) / 'check'
    main.write_text('import SwiftUI\n' + renderer + '\n' + checks)
    device_views = root / 'boringNotch/components/Notch/DeviceActivity.swift'
    subprocess.run(['xcrun', 'swiftc', str(main), str(device_views), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
