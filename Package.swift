// swift-tools-version:5.9
// NOTE: This Package.swift exists only as a developer convenience for type-checking
// the Swift sources without Xcode. The real build is driven by xcodegen + Xcode (see README).
// `swift build` will not produce a runnable .app — entitlements and Info.plist live in Project.yml.
import PackageDescription

let package = Package(
    name: "WhisperPilot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WhisperPilot",
            path: "Sources/WhisperPilot"
        )
    ]
)
