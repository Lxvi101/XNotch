// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shelves",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Shelves", type: .dynamic, targets: ["Shelves"])
    ],
    dependencies: [
        .package(path: "../../Kit")
    ],
    targets: [
        .target(name: "Shelves", dependencies: [.product(name: "XNotchKit", package: "Kit")]),
        .testTarget(name: "ShelvesTests", dependencies: ["Shelves"])
    ]
)
