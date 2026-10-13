// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIUsage",
    platforms: [.macOS(.v14)],
    products: [
        // An extension is a loadable bundle, so its product is a dynamic library.
        .library(name: "AIUsage", type: .dynamic, targets: ["AIUsage"])
    ],
    dependencies: [
        .package(path: "../../Kit")
    ],
    targets: [
        // SQLite3, Security and LocalAuthentication come from the macOS SDK and link automatically.
        .target(name: "AIUsage", dependencies: [.product(name: "XNotchKit", package: "Kit")]),
        .testTarget(name: "AIUsageTests", dependencies: ["AIUsage"], resources: [.copy("Fixtures")])
    ]
)
