// swift-tools-version: 6.2
// AgentXKit holds all of AgentX's code (UI + core). The Xcode app target in
// ../project.yml is a thin wrapper around it, and `AgentXDev` lets you build
// and run the app with plain `swift build` (see ../scripts/run-dev.sh).
import PackageDescription

let package = Package(
    name: "AgentXKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AgentXKit", targets: ["AgentXKit"]),
        .executable(name: "AgentXDev", targets: ["AgentXDev"]),
    ],
    dependencies: [
        // Terminal emulator for the "Terminal" tab (runs the real `claude` CLI).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.99.3"),
        // Markdown rendering for Claude's replies.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.1"),
    ],
    targets: [
        .target(
            name: "AgentXKit",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ]
        ),
        .executableTarget(name: "AgentXDev", dependencies: ["AgentXKit"]),
        .testTarget(name: "AgentXKitTests", dependencies: ["AgentXKit"]),
    ]
)
