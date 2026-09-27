// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AppIntervention",
    defaultLocalization: "en",
    platforms: [
        // iOS is the product. macOS exists so the core runs under `swift test` on the host and
        // DocC builds with the standard workflow; UIKit-only code is behind `#if os(iOS)`.
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        // Models, stores, the pure policy, the coordinator. Foundation only.
        .library(name: "AppIntervention", targets: ["AppIntervention"]),
        // Adapters for the host's own AppIntent types. Ships no intents.
        .library(name: "AppInterventionIntents", targets: ["AppInterventionIntents"]),
        // Themeable SwiftUI: pause screen, automation setup guide, open-count summary.
        .library(name: "AppInterventionUI", targets: ["AppInterventionUI"]),
        // "Put the phone down" sessions: pure state machine + UIKit event source.
        .library(name: "AppInterventionFocus", targets: ["AppInterventionFocus"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", .upToNextMajor(from: "1.4.0"))
    ],
    targets: [
        // MARK: - Core (no framework beyond Foundation)
        .target(
            name: "AppIntervention",
            path: "Sources/AppIntervention"
        ),

        // MARK: - App Intents adapters
        .target(
            name: "AppInterventionIntents",
            dependencies: ["AppIntervention"],
            path: "Sources/AppInterventionIntents"
        ),

        // MARK: - UI (SwiftUI + system frameworks only)
        .target(
            name: "AppInterventionUI",
            dependencies: ["AppIntervention"],
            path: "Sources/AppInterventionUI",
            resources: [.process("Resources")]
        ),

        // MARK: - Phone-down sessions
        .target(
            name: "AppInterventionFocus",
            dependencies: ["AppIntervention"],
            path: "Sources/AppInterventionFocus"
        ),

        // MARK: - Tests
        .testTarget(
            name: "AppInterventionTests",
            dependencies: ["AppIntervention"],
            path: "Tests/AppInterventionTests"
        ),
        .testTarget(
            name: "AppInterventionFocusTests",
            dependencies: ["AppInterventionFocus", "AppIntervention"],
            path: "Tests/AppInterventionFocusTests"
        ),
        .testTarget(
            name: "AppInterventionUITests",
            dependencies: ["AppInterventionUI", "AppIntervention"],
            path: "Tests/AppInterventionUITests"
        ),
        .testTarget(
            name: "AppInterventionIntentsTests",
            dependencies: ["AppInterventionIntents", "AppIntervention"],
            path: "Tests/AppInterventionIntentsTests"
        )
    ]
)
