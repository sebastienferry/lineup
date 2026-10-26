// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Lineup",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lineup", targets: ["Lineup"]),
        .executable(name: "lineup-notify", targets: ["lineup-notify"]),
    ],
    targets: [
        // Everything that can be tested without a window: models, parsing, the CLI and REST clients.
        .target(name: "LineupCore"),
        // The menu bar app itself.
        .executableTarget(name: "Lineup", dependencies: ["LineupCore"]),
        // The inbox's command line and MCP server, for scripts, hooks and Claude.
        .executableTarget(name: "lineup-notify", dependencies: ["LineupCore"], path: "Sources/LineupNotify"),
        // The checks of LineupCore, as a plain executable: XCTest and Swift Testing both need
        // Xcode, and the Command Line Tools alone have neither. Run with `swift run lineup-checks`.
        .executableTarget(name: "lineup-checks", dependencies: ["LineupCore"], path: "Sources/LineupChecks"),
    ]
)
