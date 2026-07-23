// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "superUsage",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .executable(name: "superUsage", targets: ["SuperUsageApp"]),
        .executable(name: "superusage-cli", targets: ["SuperUsageCLI"]),
        .library(name: "UsageSync", targets: ["UsageSync"])
    ],
    dependencies: [
        // The de-facto standard recorder + global hotkey for Mac apps (System Settings-style field).
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
        // In-app auto-updates (appcast + EdDSA-signed downloads). 2.9.4 fixes the update window opening
        // behind other apps for menu-bar (dockless) apps (sparkle-project/Sparkle#2889).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"),
        // Anonymous, opt-out product analytics (official, MIT-licensed, first-party Swift SDK).
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.62.0")
    ],
    targets: [
        .target(
            name: "UsageSync",
            path: "Sources/UsageSync",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "SuperUsage",
            dependencies: [
                "UsageSync",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "PostHog", package: "posthog-ios")
            ],
            path: "Sources/SuperUsage",
            resources: [
                .copy("Resources/ProviderIcons"),
                .copy("Resources/pricing_supplement.json"),
                .copy("Resources/pricing_litellm_snapshot.json"),
                .copy("Resources/pricing_models_dev_snapshot.json")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "SuperUsageApp",
            dependencies: ["SuperUsage"],
            path: "Sources/SuperUsageApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "SuperUsageCLI",
            dependencies: ["SuperUsage"],
            path: "Sources/SuperUsageCLI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "UsageSyncTests",
            dependencies: ["UsageSync"],
            path: "Tests/UsageSyncTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SuperUsageTests",
            dependencies: ["SuperUsage"],
            path: "Tests/SuperUsageTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SuperUsageCLITests",
            dependencies: ["SuperUsageCLI"],
            path: "Tests/SuperUsageCLITests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
