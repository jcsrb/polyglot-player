// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Polyglot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Polyglot",
            path: "Sources/Polyglot"
        )
    ]
)
