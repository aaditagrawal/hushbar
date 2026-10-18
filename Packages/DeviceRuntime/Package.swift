// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeviceRuntime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DeviceRuntime", targets: ["DeviceRuntime"])
    ],
    dependencies: [
        .package(path: "../DeviceProtocol"),
        .package(path: "../SupportDiagnostics")
    ],
    targets: [
        .target(
            name: "DeviceRuntime",
            dependencies: [
                .product(name: "DeviceProtocol", package: "DeviceProtocol"),
                .product(name: "SupportDiagnostics", package: "SupportDiagnostics")
            ],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "DeviceRuntimeTests",
            dependencies: [
                "DeviceRuntime",
                .product(name: "DeviceProtocol", package: "DeviceProtocol")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
