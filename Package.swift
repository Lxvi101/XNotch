// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "XNotch",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Kit"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "XNotch",
            dependencies: [
                .product(name: "XNotchKit", package: "Kit"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "XNotch"
        )
    ]
)
