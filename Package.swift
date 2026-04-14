// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "GSD",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GSD",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        ),
    ]
)
