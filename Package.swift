// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Mulligan",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MulliganCore", targets: ["MulliganCore"]),
        .executable(name: "mulligan", targets: ["mulligan"]),
        .executable(name: "MulliganBar", targets: ["MulliganBar"]),
    ],
    targets: [
        .target(name: "MulliganCore", swiftSettings: v5),
        .executableTarget(name: "mulligan", dependencies: ["MulliganCore"], swiftSettings: v5),
        .executableTarget(name: "MulliganBar", dependencies: ["MulliganCore"], swiftSettings: v5),
        .testTarget(name: "MulliganCoreTests", dependencies: ["MulliganCore"], swiftSettings: v5),
    ]
)
