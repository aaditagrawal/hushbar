// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeviceProtocol",
    products: [
        .library(name: "DeviceProtocol", targets: ["DeviceProtocol"])
    ],
    targets: [
        .target(name: "DeviceProtocol", resources: [.process("Resources")]),
        .testTarget(name: "DeviceProtocolTests", dependencies: ["DeviceProtocol"])
    ],
    swiftLanguageModes: [.v6]
)
