// swift-tools-version:5.9
// Pure Swift package for running `swift test` on macOS without needing an iPhone.
// The iOS app + Packet Tunnel extension build from `project.yml` (XcodeGen).
import PackageDescription

let package = Package(
    name: "USBProxy",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ProxyCore", targets: ["ProxyCore"]),
    ],
    targets: [
        .target(
            name: "ProxyCore",
            path: "ios/ProxyCore"
        ),
        .testTarget(
            name: "ProxyCoreTests",
            dependencies: ["ProxyCore"],
            path: "ios/Tests"
        ),
    ]
)
