// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "HearthKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .watchOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "HearthModel", targets: ["HearthModel"]),
        .library(name: "HearthAPI", targets: ["HearthAPI"]),
        .library(name: "HearthData", targets: ["HearthData"]),
        .library(name: "HearthPlayback", targets: ["HearthPlayback"]),
        .library(name: "HearthUI", targets: ["HearthUI"]),
        .library(name: "HearthIntents", targets: ["HearthIntents"]),
    ],
    targets: [
        .target(name: "HearthModel", swiftSettings: swiftSettings),
        .target(name: "HearthAPI", dependencies: ["HearthModel"], swiftSettings: swiftSettings),
        .target(name: "HearthData", dependencies: ["HearthModel", "HearthAPI"], swiftSettings: swiftSettings),
        .target(name: "HearthPlayback", dependencies: ["HearthModel", "HearthAPI", "HearthData"], resources: [.process("Resources")], swiftSettings: swiftSettings),
        .target(name: "HearthUI", dependencies: ["HearthModel", "HearthData"], resources: [.process("Resources")], swiftSettings: swiftSettings),
        .target(name: "HearthIntents", dependencies: ["HearthModel", "HearthData", "HearthPlayback"], swiftSettings: swiftSettings),

        .testTarget(name: "HearthModelTests", dependencies: ["HearthModel"]),
        .testTarget(name: "HearthAPITests", dependencies: ["HearthAPI"], resources: [.copy("Fixtures")]),
        .testTarget(name: "HearthDataTests", dependencies: ["HearthData"]),
        .testTarget(name: "HearthPlaybackTests", dependencies: ["HearthPlayback", "HearthModel"]),
    ]
)
