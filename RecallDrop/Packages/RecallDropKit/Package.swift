// swift-tools-version: 6.0
//
//  RecallDropKit
//
//  Platform-independent core of RecallDrop: AI provider clients (BYOK),
//  the agent persona system, structured-output parsing, search, reminder
//  scheduling rules and link metadata parsing. Depends on Foundation only,
//  so it builds and tests on macOS, iOS and Linux alike.
//

import PackageDescription

let package = Package(
    name: "RecallDropKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "RecallDropKit", targets: ["RecallDropKit"])
    ],
    targets: [
        .target(name: "RecallDropKit"),
        .testTarget(
            name: "RecallDropKitTests",
            dependencies: ["RecallDropKit"]
        )
    ]
)
