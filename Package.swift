// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CPAQuotaBar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CPAQuotaCore", targets: ["CPAQuotaCore"]),
        .executable(name: "CPAQuotaBar", targets: ["CPAQuotaBar"]),
    ],
    targets: [
        .target(name: "CPAQuotaCore"),
        .executableTarget(name: "CPAQuotaBar", dependencies: ["CPAQuotaCore"]),
        .testTarget(name: "CPAQuotaCoreTests", dependencies: ["CPAQuotaCore"]),
    ]
)
