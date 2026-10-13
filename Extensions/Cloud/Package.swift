// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cloud",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Cloud", type: .dynamic, targets: ["Cloud"])
    ],
    dependencies: [
        .package(path: "../../Kit")
    ],
    targets: [
        .target(name: "Cloud", dependencies: [.product(name: "XNotchKit", package: "Kit")]),
        .testTarget(name: "CloudTests", dependencies: ["Cloud"])
    ]
)
