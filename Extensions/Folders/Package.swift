// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Folders",
    platforms: [.macOS(.v14)],
    products: [
        // An extension is a loadable bundle, so its product is a dynamic library.
        .library(name: "Folders", type: .dynamic, targets: ["Folders"])
    ],
    dependencies: [
        .package(path: "../../Kit")
    ],
    targets: [
        .target(name: "Folders", dependencies: [.product(name: "XNotchKit", package: "Kit")])
    ]
)
