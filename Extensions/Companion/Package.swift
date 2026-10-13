// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Companion",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Companion", type: .dynamic, targets: ["Companion"])
    ],
    dependencies: [
        .package(path: "../../Kit"),
        .package(path: "../../Shared/XNotchLink")
    ],
    targets: [
        .target(name: "Companion", dependencies: [
            .product(name: "XNotchKit", package: "Kit"),
            .product(name: "XNotchLink", package: "XNotchLink")
        ]),
        .testTarget(name: "CompanionTests", dependencies: ["Companion"])
    ]
)
