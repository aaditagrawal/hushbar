import Foundation

enum ProtocolResources {
    static var bundle: Bundle {
        // Older SwiftPM accessors do not search Contents/Resources. Prefer the
        // standard signed-app location, then use SwiftPM's test/CLI lookup.
        if let root = Bundle.main.resourceURL,
           let bundle = Bundle(url: root.appendingPathComponent("DeviceProtocol_DeviceProtocol.bundle")) { return bundle }
        return Bundle.module
    }
}
