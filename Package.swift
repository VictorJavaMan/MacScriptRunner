// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacScriptRunner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacScriptRunner", targets: ["MacScriptRunner"])
    ],
    targets: [
        .executableTarget(
            name: "MacScriptRunner",
            path: "Sources/MacScriptRunner"
        )
    ]
)
