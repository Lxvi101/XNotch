// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vitals",
    platforms: [.macOS(.v14)],
    products: [
        // An extension is a loadable bundle, so its product is a dynamic library.
        .library(name: "Vitals", type: .dynamic, targets: ["Vitals"])
    ],
    dependencies: [
        .package(path: "../../Kit")
    ],
    targets: [
        // IOKit comes from the macOS SDK and links automatically.
        .target(name: "Vitals", dependencies: [.product(name: "XNotchKit", package: "Kit")]),
        .testTarget(name: "VitalsTests", dependencies: ["Vitals"])
    ]
)
