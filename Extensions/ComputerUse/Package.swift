// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ComputerUse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ComputerUse", type: .dynamic, targets: ["ComputerUse"])
    ],
    dependencies: [
        .package(path: "../../Kit")
    ],
    targets: [
        .target(name: "ComputerUse", dependencies: [.product(name: "XNotchKit", package: "Kit")]),
        .testTarget(name: "ComputerUseTests", dependencies: ["ComputerUse"])
    ]
)
