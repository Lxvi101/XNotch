// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MenuBarFolders",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MenuBarFolders", type: .dynamic, targets: ["MenuBarFolders"])
    ],
    dependencies: [
        .package(path: "../../Kit")
    ],
    targets: [
        .target(name: "MenuBarFolders", dependencies: [.product(name: "XNotchKit", package: "Kit")])
    ]
)
