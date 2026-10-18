// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SupportDiagnostics",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SupportDiagnostics", targets: ["SupportDiagnostics"])],
    targets: [
        .target(name: "SupportDiagnostics"),
        .testTarget(name: "SupportDiagnosticsTests", dependencies: ["SupportDiagnostics"])
    ],
    swiftLanguageModes: [.v6]
)
