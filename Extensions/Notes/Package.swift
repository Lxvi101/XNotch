// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Notes",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Notes", type: .dynamic, targets: ["Notes"])
    ],
    dependencies: [
        .package(path: "../../Kit")
    ],
    targets: [
        .target(name: "Notes", dependencies: [.product(name: "XNotchKit", package: "Kit")]),
        .testTarget(name: "NotesTests", dependencies: ["Notes"])
    ]
)
