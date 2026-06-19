// swift-tools-version: 5.9
import PackageDescription

// Engram — the engine for a local-first AI memory layer.
// Codename "Engram" (a memory trace) — placeholder, easy to rename later.
// Pure logic + Foundation, no third-party dependencies. The macOS menubar app and the
// MCP server will be thin shells over this package (mirrors the Council/CouncilKit split).
let package = Package(
    name: "Engram",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Engram", targets: ["Engram"]),
        .executable(name: "engram-mcp", targets: ["engram-mcp"]),
        .executable(name: "engram-capture", targets: ["engram-capture"]),
        .executable(name: "engram-app", targets: ["engram-app"]),
    ],
    dependencies: [
        // ONLY the GUI app links Sparkle (in-app updates). The library + MCP + capture stay dependency-free.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "Engram"),
        .executableTarget(name: "engram-mcp", dependencies: ["Engram"]),
        .executableTarget(name: "engram-capture", dependencies: ["Engram"]),
        .executableTarget(name: "engram-app", dependencies: [
            "Engram",
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        .testTarget(name: "EngramTests", dependencies: ["Engram"]),
    ]
)
