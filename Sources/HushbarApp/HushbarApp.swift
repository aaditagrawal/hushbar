import DeviceRuntime
import SwiftUI
import AppKit

@main
@MainActor
enum HushbarEntry {
    private static var delegate: ApplicationDelegate?
    static func main() {
        do {
            if let directory = try PanelSnapshots.requestedDirectory() {
                NSApplication.shared.setActivationPolicy(.prohibited)

                try PanelSnapshots.render(to: directory)
                exit(0)
            }
            let validation = try NativeValidation.requestedDirectory()
            let eqRead = try NativeValidation.requestedDirectory(flag: "--read-advanced-eq")
            NSApplication.shared.setActivationPolicy(.accessory)

            let delegate = ApplicationDelegate(validationDirectory: validation, eqReadDirectory: eqRead)
            Self.delegate = delegate
            NSApplication.shared.delegate = delegate
            NSApplication.shared.run()
        } catch {
            FileHandle.standardError.write(Data("Hushbar: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
