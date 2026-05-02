// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JarvisNoteCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"]),
        .library(name: "AIKit", targets: ["AIKit"]),
        .library(name: "StorageKit", targets: ["StorageKit"]),
        .library(name: "DependencyLifecycle", targets: ["DependencyLifecycle"]),
        .library(name: "DictationKit", targets: ["DictationKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.2.0"),
    ],
    targets: [
        // MARK: - Library targets

        .target(
            name: "CaptureKit",
            dependencies: [
                "StorageKit",
            ],
            path: "Sources/CaptureKit"
        ),
        .target(
            name: "TranscriptionKit",
            dependencies: [
                "StorageKit",
            ],
            path: "Sources/TranscriptionKit"
        ),
        .target(
            name: "AIKit",
            dependencies: [
                "StorageKit",
            ],
            path: "Sources/AIKit"
        ),
        .target(
            name: "StorageKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "KeychainAccess", package: "KeychainAccess"),
            ],
            path: "Sources/StorageKit"
        ),
        .target(
            name: "DependencyLifecycle",
            dependencies: [
                "StorageKit",
            ],
            path: "Sources/DependencyLifecycle"
        ),
        .target(
            name: "DictationKit",
            dependencies: [
                "TranscriptionKit",
                "AIKit",
                // KeyboardShortcuts added when HotkeyMonitor.swift lands in Phase C
            ],
            path: "Sources/DictationKit"
        ),

        // MARK: - Test targets

        .testTarget(
            name: "CaptureKitTests",
            dependencies: ["CaptureKit"],
            path: "Tests/CaptureKitTests",
            swiftSettings: [
                .swiftLanguageVersion(.v5),
            ]
        ),
        .testTarget(
            name: "TranscriptionKitTests",
            dependencies: ["TranscriptionKit"],
            path: "Tests/TranscriptionKitTests"
        ),
        .testTarget(
            name: "AIKitTests",
            dependencies: ["AIKit"],
            path: "Tests/AIKitTests"
        ),
        .testTarget(
            name: "StorageKitTests",
            dependencies: ["StorageKit"],
            path: "Tests/StorageKitTests"
        ),
        .testTarget(
            name: "DependencyLifecycleTests",
            dependencies: ["DependencyLifecycle"],
            path: "Tests/DependencyLifecycleTests"
        ),
        .testTarget(
            name: "DictationKitTests",
            dependencies: ["DictationKit"],
            path: "Tests/DictationKitTests"
        ),
    ]
)
