// swift-tools-version: 6.0
// Unit tests for FreeAudio's pure logic (FreeAudio/Core). The app itself is built by
// scripts/build-app-clt.sh or Xcode; this package only exists so `swift test` can run
// on the Command Line Tools. Core files are compiled into both.
import PackageDescription

let package = Package(
    name: "FreeAudioCore",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "FreeAudioCore", path: "FreeAudio/Core"),
        .testTarget(
            name: "FreeAudioCoreTests",
            dependencies: ["FreeAudioCore"],
            path: "Tests/FreeAudioCoreTests"
        ),
    ]
)
