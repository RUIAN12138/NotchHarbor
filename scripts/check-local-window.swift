import AppKit
import CoreGraphics

let path = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
let id = Bundle(url: path)?.bundleIdentifier
let needsWindow = CommandLine.arguments.contains("--window")
let deadline = Date().addingTimeInterval(18)
while Date() < deadline {
    let matches = NSRunningApplication.runningApplications(withBundleIdentifier: id ?? "")
    if matches.count == 1, let app = matches.first, app.isFinishedLaunching,
       app.bundleURL?.resolvingSymlinksInPath() == path {
        if !needsWindow {
            print(app.processIdentifier)
            exit(EXIT_SUCCESS)
        }
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        if !app.isHidden, windows.contains(where: { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            // The notch and menu popover are smaller, above normal window level.
            return rect.width >= 640 && rect.height >= 450
        }) {
            print(app.processIdentifier)
            exit(EXIT_SUCCESS)
        }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
}

fputs(needsWindow ? "Notch Harbor settings did not become visible.\n" : "Notch Harbor did not finish launching.\n", stderr)
exit(EXIT_FAILURE)
