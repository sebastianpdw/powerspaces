// swift-tools-version:6.0
import PackageDescription

// Swift 6 migration (review finding A), warnings-first: the language mode stays at
// v5 (so the build keeps compiling) while complete strict-concurrency checking is
// enabled as *warnings*, surfacing data-race issues for incremental fixing before a
// later flip to the Swift 6 language mode.
let concurrencyWarnings: [SwiftSetting] = [.enableUpcomingFeature("StrictConcurrency")]

let package = Package(
    name: "powerspaces",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpaceKit", targets: ["SpaceKit"]),
        .executable(name: "powerspaces", targets: ["powerspaces"]),
        .executable(name: "PowerspacesApp", targets: ["PowerspacesApp"]),
        // Dependency-free test runner: XCTest/Swift Testing aren't available with
        // Command Line Tools only, so tests run as a normal executable.
        .executable(name: "spacekit-tests", targets: ["SpaceKitTestRunner"]),
    ],
    targets: [
        .target(name: "SpaceKit", swiftSettings: concurrencyWarnings),
        // The "faster desktop switch" engine: a small C target that posts a
        // synthetic, no-animation Dock-swipe via private CGEvent fields (kept in C
        // because casting arbitrary field numbers to CGEventField is trivial there).
        // Adapted from InstantSpaceSwitcher (MIT) — see CSpaceSwitch.c.
        .target(name: "CSpaceSwitch",
                linkerSettings: [.linkedFramework("ApplicationServices")]),
        .executableTarget(name: "powerspaces", dependencies: ["SpaceKit"], swiftSettings: concurrencyWarnings),
        .executableTarget(name: "PowerspacesApp", dependencies: ["SpaceKit", "CSpaceSwitch"], swiftSettings: concurrencyWarnings),
        .executableTarget(name: "SpaceKitTestRunner", dependencies: ["SpaceKit"], swiftSettings: concurrencyWarnings),
    ],
    swiftLanguageModes: [.v5]
)
