// swift-tools-version:5.10
import PackageDescription

// Memory — the menu-bar face of the memory layer on this Mac. The app drives
// two programs it does not own: the screenctx collector (a launchd agent) and
// the recall CLI. It stores nothing of its own.
//
// Two targets, the same split every app in this family uses. MemoryBarCore is
// pure: parsing, merging, and the launchctl argument arrays, with no AppKit
// and no window, so all of it is testable against captured output. MemoryBar
// is the app, and holds the view layer and the polling.
let package = Package(
    name: "MemoryBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MemoryBarCore", targets: ["MemoryBarCore"]),
        .executable(name: "memory-bar", targets: ["MemoryBar"]),
    ],
    targets: [
        .target(name: "MemoryBarCore"),
        .executableTarget(name: "MemoryBar", dependencies: ["MemoryBarCore"]),
        // The app's own window rules: the menu bar a normal window gets, and
        // when the app goes back to being a menu-bar app. AppKit only, no
        // window is opened.
        .testTarget(name: "MemoryBarTests", dependencies: ["MemoryBar"]),
        .testTarget(
            name: "MemoryBarCoreTests",
            dependencies: ["MemoryBarCore"],
            // Captured output from the real CLIs. The parsers are tested
            // against what the programs actually print, not against a shape
            // remembered while writing them.
            resources: [.copy("Fixtures")]
        ),
    ]
)
