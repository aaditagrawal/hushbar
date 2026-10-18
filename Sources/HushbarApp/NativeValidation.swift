import DeviceRuntime
import AppKit
import Foundation

/// Exercises this app's own status item and native windows. No external GUI automation.
@MainActor
enum NativeValidation {
    static func requestedDirectory(flag: String = "--validate-native-ui", arguments: [String] = CommandLine.arguments) throws -> URL? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
            throw SnapshotFailure(message: "Usage: Hushbar \(flag) <output-directory>")
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static func run(controller: MenuBarController, session: DeviceSession, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller.popover.animates = false
        // Keep automated checks open while another app or the user has focus.
        controller.popover.behavior = .applicationDefined
        try await Task.sleep(for: .milliseconds(200))
        var measurements: [[String: Any]] = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            controller.popover.appearance = NSAppearance(named: appearance)
            session.setEQ(5)
            controller.navigation.path = []
            for page in [PanelPage.main, .advancedEQ, .device, .main] {
                if page == .advancedEQ { controller.navigation.selectEQ(6, session: session) }
                else { controller.navigation.path = page == .main ? [] : [page] }
                controller.showPopover()
                for _ in 0..<8 { try await Task.sleep(for: .milliseconds(50)) }
                guard let button = controller.statusItem.button, let barWindow = button.window,
                      let window = controller.popover.contentViewController?.view.window,
                      controller.popover.isShown else {
                    throw SnapshotFailure(message: "Native popover did not open. shown=\(controller.popover.isShown), status window=\(String(describing: controller.statusItem.button?.window)), windows=\(NSApp.windows)")
                }
                let anchor = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
                let frame = window.frame
                let gap = anchor.minY - frame.maxY
                guard abs(gap) <= 1, frame.minX <= anchor.midX, frame.maxX >= anchor.midX else {
                    throw SnapshotFailure(message: "Popover detached from its status item: anchor \(anchor), window \(frame), gap \(gap).")
                }
                guard controller.navigation.page == page else { throw SnapshotFailure(message: "Failed to open \(page).") }
                let file = "\(name)-\(measurements.count)-\(page.rawValue).png"
                try capture(window: window, to: directory.appendingPathComponent(file))
                measurements.append(["appearance": name, "page": page.rawValue, "anchor": NSStringFromRect(anchor),
                                     "window": NSStringFromRect(frame), "gap": gap, "screenshot": file])
                print("\(name) \(page.rawValue): gap \(gap) pt, window \(frame)")
            }
            controller.popover.performClose(nil)
        }
        controller.showSettings()
        try await Task.sleep(for: .milliseconds(300))
        guard let settings = NSApp.keyWindow, settings.title == "Hushbar Settings", settings.styleMask.contains(.titled) else {
            throw SnapshotFailure(message: "Native Settings window did not open.")
        }
        let settingsSize = settings.contentLayoutRect.size
        guard abs(settingsSize.width - AppSettings.width) <= 1,
              abs(settingsSize.height - AppSettings.height) <= 1 else {
            throw SnapshotFailure(message: "Native Settings content has an unexpected size: \(settingsSize).")
        }
        try capture(window: settings, to: directory.appendingPathComponent("settings-window.png"))
        settings.performClose(nil)
        let report = try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
        try report.write(to: directory.appendingPathComponent("positioning.json"), options: .atomic)
        print("Native popover positioning, Advanced navigation, page resizing and Settings passed.")
    }

    static func readAdvancedEQ(session: DeviceSession, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for _ in 0..<400 {
            if session.ready { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard session.ready else { throw SnapshotFailure(message: "Device did not connect for EQ read: \(session.error ?? session.status)") }
        await session.loadEqualizer(advanced: true)
        guard let profile = session.state.advancedBands, session.error == nil else {
            throw SnapshotFailure(message: "Advanced band read failed: \(session.error ?? "No bands returned")")
        }
        let report: [String: Any] = ["model": session.model?.base ?? "", "firmware": session.state.firmware,
                                   "bands": profile.bands.count, "frequencies": profile.bands.map(\.frequency),
                                   "gains": profile.bands.map(\.gain), "profile": profile.profile]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("advanced-eq-read.json"), options: .atomic)
    }

    private static func capture(window: NSWindow, to file: URL) throws {
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SnapshotFailure(message: "Could not capture this app's native window.")
        }
        window.displayIfNeeded()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotFailure(message: "Could not encode native window screenshot.")
        }
        try png.write(to: file, options: .atomic)
    }
}
