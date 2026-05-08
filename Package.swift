// swift-tools-version:5.9
// NOTE: This Package.swift exists for type-checking and running the smoke-test runner
// without Xcode. The real macOS app build is driven by xcodegen + Xcode (see README) —
// entitlements and Info.plist live in Project.yml.
//
// Why a custom smoke runner instead of swift-testing/XCTest?
// Apple's Command Line Tools toolchain ships a partial Testing.framework (no
// _Testing_Foundation submodule) and no XCTest.framework. Tests therefore can't run
// without a full Xcode install. The smoke runner depends on nothing but Swift stdlib
// and exercises the pure-logic modules end-to-end.
//
// The library target excludes the SwiftUI @main and AppDelegate so it can be linked
// into the smoke runner. Those two files are app-entry-only and are still picked up
// by the Xcode build via Project.yml.
import PackageDescription

let package = Package(
    name: "WhisperPilot",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "WhisperPilot",
            path: "Sources/WhisperPilot",
            exclude: [
                "App/WhisperPilotApp.swift",
                "App/AppDelegate.swift"
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "SmokeTests",
            dependencies: ["WhisperPilot"],
            path: "Tools/SmokeTests"
        )
    ]
)
