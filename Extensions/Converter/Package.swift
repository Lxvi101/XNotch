// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Converter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Converter", type: .dynamic, targets: ["Converter"])
    ],
    dependencies: [
        .package(path: "../../Kit")
    ],
    targets: [
        .target(name: "Converter", dependencies: [.product(name: "XNotchKit", package: "Kit")]),
        .testTarget(name: "ConverterTests", dependencies: ["Converter"])
    ]
)
