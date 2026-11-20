"""Check production UTF-16 word, email, link, and drag selection."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'boringNotch/components/Clipboard/ClipboardHistoryView.swift').read_text()
source = source.split('// === CLIPBOARD_SELECTION_BEGIN ===')[1].split('// === CLIPBOARD_SELECTION_END ===')[0]
checks = r'''
let value = "📬 邮箱 Alice+tag@example.co.uk，资料 https://example.com/path?q=1。\nstart final word"
let string = value as NSString
let tokens = ClipboardTextTokens(text: value)
func pick(_ probe: String) -> String? {
    tokens.token(at: string.range(of: probe).location).map { string.substring(with: $0) }
}
assert(pick("tag") == "Alice+tag@example.co.uk")
assert(pick("co.uk") == "Alice+tag@example.co.uk")
assert(pick("path") == "https://example.com/path?q=1")
assert(pick("邮箱") == "邮箱")
assert(pick("📬") == "📬")
assert(tokens.token(at: 2) == nil)
let selection = string.range(of: "art fin")
assert(tokens.expanding(selection).map { string.substring(with: $0) } == "start final")
assert(tokens.expanding(string.range(of: "tag@example")).map { string.substring(with: $0) } == "Alice+tag@example.co.uk")
assert(tokens.expanding(NSRange(location: string.length, length: 1)) == nil)
let blocks = tokens.blocks(in: NSRange(location: 0, length: string.length)).map { string.substring(with: $0) }
assert(blocks.contains("Alice+tag@example.co.uk") && blocks.contains("https://example.com/path?q=1"))
assert(!blocks.contains("tag") && !blocks.contains("path") && blocks.contains("final"))
let mixed = "blave: search-browser WebKit-based 7.0.0 mail@example.org，链接 https://brew.sh/blog/7.0.0"
let mixedTokens = ClipboardTextTokens(text: mixed)
let mixedString = mixed as NSString
let mixedBlocks = mixedTokens.blocks(in: NSRange(location: 0, length: mixedString.length))
let mixedWords = mixedBlocks.map { mixedString.substring(with: $0) }
assert(mixedWords.contains("blave:") && mixedWords.contains("search-browser") && mixedWords.contains("WebKit-based"))
assert(mixedWords.contains("7.0.0") && mixedWords.contains("mail@example.org"))
assert(mixedTokens.token(at: mixedString.range(of: "based").location).map { mixedString.substring(with: $0) } == "WebKit-based")
assert(zip(mixedBlocks, mixedBlocks.dropFirst()).allSatisfy { NSMaxRange($0.0) <= $0.1.location })
print("PASS: Chinese word, email with plus tag, full URL, emoji, drag selection and invalid ranges")
'''
with tempfile.TemporaryDirectory(prefix='notch-clip-select-') as work:
    path = Path(work) / 'main.swift'
    path.write_text('import Foundation\nimport NaturalLanguage\n' + source + checks)
    subprocess.run(['xcrun', 'swift', str(path)], check=True)
