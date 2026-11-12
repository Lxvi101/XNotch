// swift-tools-version:5.9
import PackageDescription

/// Records Walkie's real views in a scripted scene to an MP4:
/// `swift run -j 4 WalkieDemo ~/Desktop/walkie.mp4` (debug build: it uses the
/// extension's DEBUG demo hooks).
let package = Package(
    name: "WalkieDemo",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: ".."),
        .package(path: "../../../Kit")
    ],
    targets: [
        .executableTarget(name: "WalkieDemo", dependencies: [
            .product(name: "Walkie", package: "Walkie"),
            .product(name: "XNotchKit", package: "Kit")
        ])
    ]
)
