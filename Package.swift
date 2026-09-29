// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DebugTrace",
    // Deliberately lower than RAVESDK's iOS 26 floor: web-yt-dlp's player and
    // RegentChat target iOS 18 and are meant to adopt this too. That floor is
    // the reason this is its own package rather than a RAVESDK target (see
    // CLAUDE.md). macOS is declared so `swift test` has a host, and because
    // Longwave's and Oneiros's Mac targets link it. watchOS is not declared.
    platforms: [.iOS(.v17), .tvOS(.v17), .visionOS(.v1), .macOS(.v14)],
    products: [
        // The registry, the trace builder and the log/breadcrumb readers.
        // Safe for App Store builds and extensions: no listener, no UI.
        .library(name: "DebugTrace", targets: ["DebugTrace"]),
        // The capture/share/upload sheet.
        .library(name: "DebugTraceUI", targets: ["DebugTraceUI"]),
        // The HTTP + MCP listener over the registry. Its own product so a
        // submission build can leave it unlinked entirely.
        .library(name: "DebugTraceServer", targets: ["DebugTraceServer"]),
    ],
    targets: [
        .target(name: "DebugTrace"),
        .target(name: "DebugTraceUI", dependencies: ["DebugTrace"]),
        .target(name: "DebugTraceServer", dependencies: ["DebugTrace"]),
        .testTarget(name: "DebugTraceTests", dependencies: ["DebugTrace"]),
        .testTarget(name: "DebugTraceServerTests", dependencies: ["DebugTraceServer"]),
    ]
)
