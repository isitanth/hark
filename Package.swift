// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "Hark",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Hark", targets: ["HarkApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0"),
        .package(url: "https://github.com/jpsim/Yams", exact: "6.2.2"),
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-b5130-xcframework.zip",
            checksum: "033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
        ),
        .target(name: "HarkObjC", path: "Sources/HarkObjC", publicHeadersPath: "include"),
        .target(
            name: "HarkCore",
            dependencies: [
                "whisper",
                "HarkObjC",
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "HarkApp",
            dependencies: [
                "HarkCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: strict + [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "HarkCoreTests",
            dependencies: ["HarkCore", "HarkObjC"],
            path: "Tests/HarkCoreTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: strict
        ),
    ]
)
