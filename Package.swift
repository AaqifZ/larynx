// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "larynx",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The speech engine (Apache-2.0). Pinned: bump on purpose, never by accident.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        // Pure logic and storage: history, hand over, config. No UI, no network.
        .target(name: "LarynxCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // The speech model, loaded from disk only, kept warm by the app.
        .target(name: "LarynxSpeech", dependencies: [
            "LarynxCore",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        // The command: transcribe, last, history, status, models fetch, debug feed.
        .executableTarget(name: "larynx", dependencies: [
            "LarynxCore", "LarynxSpeech",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        // The menu bar app (packaged as dist/Larynx.app by scripts/build.sh). It makes no network connection.
        .executableTarget(name: "LarynxApp", dependencies: ["LarynxCore", "LarynxSpeech"]),
        // Tests without XCTest (CLT-only machine): `swift run LarynxSelfTest`.
        .executableTarget(name: "LarynxSelfTest", dependencies: ["LarynxCore"]),
    ]
)
