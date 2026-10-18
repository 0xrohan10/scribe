// swift-tools-version: 6.0
import PackageDescription

let domains = ["Core", "Capture", "Detection", "Transcription", "Intelligence", "Notes", "Session", "Persistence", "Settings"]

let package = Package(
    name: "ScribeKit",
    platforms: [.macOS("14.2")],
    products: (domains + ["Fixtures"]).map { .library(name: $0, targets: [$0]) },
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "Capture", dependencies: ["Core"]),
        .target(name: "Detection", dependencies: ["Core"]),
        .target(name: "Transcription", dependencies: ["Core", .product(name: "WhisperKit", package: "WhisperKit")]),
        .target(name: "Intelligence", dependencies: ["Core"]),
        .target(name: "Notes", dependencies: ["Core"]),
        .target(name: "Session", dependencies: ["Core"]),
        .target(name: "Persistence", dependencies: ["Core", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "Settings", dependencies: ["Core"]),
        // Fake audio and LLM for the `scribe` CLI and the app's UI-testing mode. No domain depends on it.
        .target(name: "Fixtures", dependencies: ["Core"]),

        // Records N seconds of system audio through a process tap and reports levels.
        // `swift run scribe-tapcheck --bundle com.google.Chrome --seconds 10`
        .executableTarget(name: "scribe-tapcheck", dependencies: ["Core", "Capture"], path: "Tools/TapCheck"),
        // Dev debugging: runs meetings with fake audio, transcription and LLM, dumps databases, probes the search gate.
        // `swift run scribe demo --seconds 12 --note "5:! billing is the risk" --ask "what did they just say?"`
        .executableTarget(
            name: "scribe",
            dependencies: [
                "Core", "Fixtures", "Intelligence", "Notes", "Persistence", "Session", "Settings", "Transcription",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tools/ScribeCLI"),

        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "CaptureTests", dependencies: ["Core", "Capture"]),
        .testTarget(name: "DetectionTests", dependencies: ["Core", "Detection"]),
        .testTarget(name: "TranscriptionTests", dependencies: ["Core", "Transcription"]),
        .testTarget(name: "IntelligenceTests", dependencies: ["Core", "Intelligence"]),
        .testTarget(name: "NotesTests", dependencies: ["Core", "Notes"]),
        .testTarget(name: "SessionTests", dependencies: ["Core", "Session", "Transcription"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Core", "Persistence"]),
        .testTarget(name: "SettingsTests", dependencies: ["Core", "Settings"]),
    ]
)
