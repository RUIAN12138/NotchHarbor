import AppKit
import CoreGraphics

let path = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
let id = Bundle(url: path)?.bundleIdentifier
let verifyQuietLaunch = CommandLine.arguments.contains("--quiet-launch")
let deadline = Date().addingTimeInterval(18)
var quietSince: Date?
while Date() < deadline {
    let matches = NSRunningApplication.runningApplications(withBundleIdentifier: id ?? "")
    if matches.count == 1, let app = matches.first, app.isFinishedLaunching,
       app.bundleURL?.resolvingSymlinksInPath() == path {
        if !verifyQuietLaunch {
            print(app.processIdentifier)
            exit(EXIT_SUCCESS)
        }
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let ownedWindows = windows.compactMap { window -> (layer: Int, rect: CGRect, onScreen: Bool)? in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let onScreen = (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
            return (layer, rect, onScreen)
        }
        // The panel resizes with its content. Match its top-centred placement,
        // allowing for the small Window Server inset while the screen is locked.
        let screens = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return CGDisplayBounds(id.uint32Value)
        }
        let notchReady = ownedWindows.contains { window in
            window.layer > 0 && window.rect.width > 0 && window.rect.height > 0
                && screens.contains { screen in
                    abs(window.rect.midX - screen.midX) < 12 && abs(window.rect.minY - screen.minY) < 12
                }
        }
        let settingsVisible = ownedWindows.contains {
            $0.onScreen && $0.layer == 0 && $0.rect.width >= 640 && $0.rect.height >= 450
        }
        if notchReady && !settingsVisible {
            let now = Date()
            if let quietSince, now.timeIntervalSince(quietSince) >= 0.55 {
                print(app.processIdentifier)
                exit(EXIT_SUCCESS)
            }
            quietSince = quietSince ?? now
        } else {
            quietSince = nil
        }
    } else {
        quietSince = nil
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
}

fputs(verifyQuietLaunch ? "Notch Harbor did not start with a notch window and closed settings.\n"
                        : "Notch Harbor did not finish launching.\n", stderr)
exit(EXIT_FAILURE)
