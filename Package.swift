// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Coverdesk",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Coverdesk",
            path: "Sources/Coverdesk"
        )
    ]
)
