// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Drives",
    platforms: [.macOS(.v14)],
    products: [
        // An extension is a loadable bundle, so its product is a dynamic library.
        .library(name: "Drives", type: .dynamic, targets: ["Drives"])
    ],
    dependencies: [
        .package(path: "../../Kit")
    ],
    targets: [
        // DiskArbitration comes from the macOS SDK and links automatically.
        .target(name: "Drives", dependencies: [.product(name: "XNotchKit", package: "Kit")]),
        .testTarget(name: "DrivesTests", dependencies: ["Drives"])
    ]
)
