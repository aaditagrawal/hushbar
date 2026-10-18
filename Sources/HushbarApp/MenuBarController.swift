import DeviceRuntime
import AppKit
import SwiftUI
import Observation

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    let session: DeviceSession
    private let validationDirectory: URL?
    private let eqReadDirectory: URL?
    private var controller: MenuBarController?

    init(validationDirectory: URL?, eqReadDirectory: URL? = nil) {
        self.validationDirectory = validationDirectory
        self.eqReadDirectory = eqReadDirectory
        session = validationDirectory == nil ? DeviceSession() : DeviceSession(demoBase: "B170", snapshot: true)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarController(session: session)
        self.controller = controller
        if let validationDirectory {
            Task { @MainActor in
                do {
                    try await NativeValidation.run(controller: controller, session: session, directory: validationDirectory)
                    exit(0)
                } catch {
                    try? Data(error.localizedDescription.utf8).write(to: validationDirectory.appendingPathComponent("failure.txt"))
                    FileHandle.standardError.write(Data("Native UI validation: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
        } else if let eqReadDirectory {
            Task { @MainActor in
                do {
                    try await NativeValidation.readAdvancedEQ(session: session, directory: eqReadDirectory)
                    exit(0)
                } catch {
                    try? FileManager.default.createDirectory(at: eqReadDirectory, withIntermediateDirectories: true)
                    try? Data(error.localizedDescription.utf8).write(to: eqReadDirectory.appendingPathComponent("failure.txt"))
                    exit(1)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showPopover()
        return false
    }
}

/// AppKit owns the status item and popover chrome. Every control inside is SwiftUI.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let navigation = PanelNavigation()
    private let session: DeviceSession
    private var hosted: NSHostingController<DevicePanel>!
    private var settingsWindow: NSWindow?
    private weak var anchorButton: NSStatusBarButton?

    init(session: DeviceSession) {
        self.session = session
        super.init()
        hosted = NSHostingController(rootView: DevicePanel(session: session, navigation: navigation,
            onOpenSettings: { [weak self] in self?.showSettings() },
            onSizeChange: { [weak self] size in self?.resize(to: size) }))
        hosted.sizingOptions = []
        popover.contentViewController = hosted
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: DevicePanel.width, height: 480)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
            button.font = .menuBarFont(ofSize: 0)
        }
        installApplicationMenu()
        observeSession()
    }

    private func observeSession() {
        withObservationTracking {
            guard let button = statusItem.button else { return }
            let image = NSImage(systemSymbolName: session.symbol, accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
            button.title = session.showBattery && session.ready
                ? session.state.lowestBattery.map { " \($0)%" } ?? "" : ""
            button.setAccessibilityLabel("Hushbar, \(session.status)\(button.title)")
            button.toolTip = "Hushbar · \(session.status)"
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSession() }
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil) }
        else { showPopover(from: sender) }
    }

    func showPopover(from clickedButton: NSStatusBarButton? = nil) {
        guard let button = clickedButton ?? statusItem.button else { return }
        anchorButton = button
        NSApp.activate(ignoringOtherApps: true)
        hosted.view.layoutSubtreeIfNeeded()
        resize(to: hosted.sizeThatFits(in: NSSize(width: DevicePanel.width, height: 0)))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        popover.contentViewController?.view.window?.makeKey()
        reanchorAfterLayout()
    }

    private func resize(to size: CGSize) {
        let size = NSSize(width: DevicePanel.width, height: max(180, ceil(size.height)))
        guard popover.contentSize != size else { return }
        popover.contentSize = size
        if popover.isShown, let button = anchorButton ?? statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            reanchorAfterLayout()
        }
    }

    private func reanchorAfterLayout() {
        // The first SwiftUI measurement can arrive inside AppKit's show/layout
        // pass. Reapply the native anchor after that pass has finished.
        DispatchQueue.main.async { [weak self, weak button = anchorButton] in
            guard let self, let button, self.popover.isShown, self.anchorButton === button else { return }
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        anchorButton?.highlight(false)
        anchorButton = nil
    }

    @objc func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: AppSettings(session: session)))
            window.styleMask = [.titled, .closable]
            window.title = "Hushbar Settings"
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: AppSettings.width, height: AppSettings.height))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem(title: "Hushbar", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "Hushbar")
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(settings)
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Hushbar", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApp.mainMenu = menu
    }

    @objc private func quitApplication() { session.quit() }
}
