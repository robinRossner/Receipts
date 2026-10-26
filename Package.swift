// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ReceiptsApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ReceiptsApp",
            path: "Sources/ReceiptsApp",
            resources: [
                .copy("Resources/category_taxonomy.json")
            ]
        )
    ]
)
