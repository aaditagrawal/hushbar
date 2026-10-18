import DeviceRuntime
import AppKit
import SwiftUI
import DeviceProtocol
import SupportDiagnostics

/// Deterministic fixtures for the real panel. These sessions never start discovery.
@MainActor
struct PanelSnapshotScenario {
    let device: String
    let state: String
    var page: PanelPage {
        if state == "device-settings" || devicesExpanded { return .device }
        if state == "eq-custom" { return .customEQ }
        if state == "eq-advanced" { return .advancedEQ }
        return .main
    }
    var appSettings: Bool { state.hasPrefix("settings-") }
    var devicesExpanded: Bool { state == "connections-fit-codec" || state == "connections-codec" }

    func makeSession() throws -> DeviceSession {
        let session = DeviceSession(demoBase: device == "real" ? nil : device.uppercased(), snapshot: true)
        if device == "real" {
            if state == "connecting" {
                session.connecting = true
                session.status = "Connecting to your device…"
            }
            return session
        }
        guard session.ready, session.capabilities != nil else {
            throw SnapshotFailure(message: "Could not load demo resources for \(device).")
        }
        switch state {
        case "anc-adaptive": session.setANC(.adaptive); session.setEQ(3)
        case "transparency": session.setANC(.transparency); session.setEQ(2)
        case "off": session.setANC(.off); session.setEQ(1)
        case "custom-preset": session.setANC(.off); session.setEQ(5)
        case "bass-level-4": session.setBass(true, level: 4)
        case "eq-custom": session.setEQ(5)
        case "eq-advanced": session.setEQ(6)
        case "spatial-head-tracked": session.setSpatial(1)
        case "ringing-left": session.ring("left", enabled: true)
        case "ringing": session.ring("both", enabled: true)
        case "connections-fit-codec", "connections-codec":
            session.setCodec(2)
            if let phone = session.state.dualDevices.last { session.setDualDevice(phone, connected: true) }
            if device == "b171" { session.state.fitLeft = .good; session.state.fitRight = .adjust }
        case "settings-diagnostics":
            let date = Date(timeIntervalSince1970: 1_767_225_600)
            session.diagnostics.start(environment: .current(mode: .snapshot),
                device: session.diagnosticDeviceInfo, now: date)
            session.diagnostics.stop(now: date.addingTimeInterval(1))
        default: break
        }
        if let error = session.error { throw SnapshotFailure(message: "\(device)-\(state): \(error)") }
        return session
    }
}

struct SnapshotFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Supplies Retina backing and active control drawing without ordering a window
/// on screen or activating the application. A detached hosting view caches its
/// SwiftUI layers at 1x even when the export bitmap is 2x.
@MainActor
private final class SnapshotWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@MainActor
enum PanelSnapshots {
    static let scenarios: [PanelSnapshotScenario] =
        ["default", "anc-adaptive", "transparency", "off", "bass-level-4", "eq-custom", "eq-advanced", "ringing-left", "device-settings", "settings-general", "settings-about", "settings-diagnostics", "connections-fit-codec"].map {
            PanelSnapshotScenario(device: "b171", state: $0)
        } + ["default", "custom-preset", "anc-adaptive", "transparency", "eq-custom", "eq-advanced", "spatial-head-tracked", "ringing", "device-settings", "settings-general", "settings-about", "settings-diagnostics", "connections-codec"].map {
            PanelSnapshotScenario(device: "b170", state: $0)
        } + ["empty", "connecting"].map { PanelSnapshotScenario(device: "real", state: $0) }

    static func requestedDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   arguments: [String] = CommandLine.arguments) throws -> URL? {
        let path: String
        if let index = arguments.firstIndex(of: "--render-snapshots") {
            guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
                throw SnapshotFailure(message: "Usage: Hushbar --render-snapshots <output-directory>")
            }
            path = arguments[index + 1]
        } else if let value = environment["HUSHBAR_SNAPSHOTS"] { path = value }
        else { return nil }
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SnapshotFailure(message: "The snapshot output directory must not be empty.")
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scenario in scenarios {
            for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                try autoreleasepool {
                    NSApplication.shared.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    let session = try scenario.makeSession()
                    let width: CGFloat = scenario.appSettings ? AppSettings.width : DevicePanel.width
                    let content: AnyView = scenario.appSettings
                        ? AnyView(AppSettings(session: session, about: scenario.state == "settings-about",
                                              diagnostics: scenario.state == "settings-diagnostics"))
                        : AnyView(DevicePanel(session: session, page: scenario.page))
                    let panel = content
                        .environment(\.colorScheme, scheme)
                        .environment(\.displayScale, 2)
                        .environment(\.controlActiveState, .key)
                        .transaction { $0.disablesAnimations = true }
                        .environment(\.locale, Locale(identifier: "en_US"))
                        .fixedSize(horizontal: false, vertical: true)
                    // Pickers, switches, menus and bordered buttons are AppKit-backed.
                    // ImageRenderer replaces them with yellow unsupported-view markers.
                    // Bridge the actual hierarchy through an offscreen hosting view first,
                    // then use ImageRenderer for the opaque, 2x SwiftUI image export.
                    let hosted = NSHostingView(rootView: panel)
                    hosted.appearance = NSApplication.shared.appearance
                    let window = SnapshotWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 1),
                                                styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = hosted.appearance
                    window.contentView = hosted
                    defer { window.contentView = nil; window.close() }
                    hosted.frame = NSRect(x: 0, y: 0, width: width, height: 1)
                    // The panel measures its content and feeds the height back into state;
                    // let that settle, then size the way the popover does (minimal height proposal).
                    for _ in 0..<4 {
                        hosted.layoutSubtreeIfNeeded()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    let controller = NSHostingController(rootView: panel)
                    for _ in 0..<4 {
                        controller.view.layoutSubtreeIfNeeded()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    let menuBarHeight = controller.sizeThatFits(in: CGSize(width: width, height: 0)).height
                    let size = NSSize(width: width, height: ceil(menuBarHeight))
                    window.setContentSize(size)
                    hosted.setFrameSize(size)
                    hosted.viewDidChangeBackingProperties()
                    hosted.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    guard size.height > 0,
                          let capture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2),
                                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                        throw SnapshotFailure(message: "Could not allocate offscreen panel bitmap.")
                    }
                    capture.size = size
                    hosted.appearance?.performAsCurrentDrawingAppearance {
                        hosted.cacheDisplay(in: hosted.bounds, to: capture)
                    }
                    guard let capturedImage = capture.cgImage else {
                        throw SnapshotFailure(message: "Could not capture native panel controls.")
                    }
                    let renderer = ImageRenderer(content:
                        Image(decorative: capturedImage, scale: 2)
                            .frame(width: size.width, height: size.height)
                            .background(Color(white: scheme == .dark ? 0.14 : 0.94)))
                    renderer.scale = 2
                    renderer.isOpaque = true
                    renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
                    guard let image = renderer.cgImage else {
                        throw SnapshotFailure(message: "ImageRenderer produced no image for \(scenario.device)-\(scenario.state)-\(name).")
                    }
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    bitmap.size = NSSize(width: Double(image.width) / 2, height: Double(image.height) / 2)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw SnapshotFailure(message: "Could not encode PNG.")
                    }
                    let file = directory.appendingPathComponent("\(scenario.device)-\(scenario.state)-\(name).png")
                    try png.write(to: file, options: .atomic)
                    print(file.path)
                }
            }
        }
    }
}
