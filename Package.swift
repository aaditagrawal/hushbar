// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hushbar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hushbar", targets: ["HushbarApp"])
    ],
    dependencies: [
        .package(path: "Packages/DeviceProtocol"),
        .package(path: "Packages/DeviceRuntime"),
        .package(path: "Packages/SupportDiagnostics")
    ],
    targets: [
        .executableTarget(
            name: "HushbarApp",
            dependencies: [
                .product(name: "DeviceProtocol", package: "DeviceProtocol"),
                .product(name: "DeviceRuntime", package: "DeviceRuntime"),
                .product(name: "SupportDiagnostics", package: "SupportDiagnostics")
            ]
        ),
        .testTarget(
            name: "HushbarAppTests",
            dependencies: [
                "HushbarApp",
                .product(name: "DeviceProtocol", package: "DeviceProtocol"),
                .product(name: "DeviceRuntime", package: "DeviceRuntime"),
                .product(name: "SupportDiagnostics", package: "SupportDiagnostics")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
