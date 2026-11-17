// swift-tools-version: 6.2
// AgentXRemote: what the Mac app and the iPhone companion share — the
// encrypted, mutually authenticated connection between them, the pairing
// code, and the messages they exchange. No third-party dependencies.
import PackageDescription

let package = Package(
    name: "RemoteKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "AgentXRemote", targets: ["AgentXRemote"]),
    ],
    targets: [
        .target(name: "AgentXRemote"),
        .testTarget(name: "AgentXRemoteTests", dependencies: ["AgentXRemote"]),
    ]
)
