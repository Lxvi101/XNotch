// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Walkie",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Walkie", type: .dynamic, targets: ["Walkie"])
    ],
    dependencies: [
        .package(path: "../../Kit"),
        // X-Wing and ML-DSA-65 from its vendored BoringSSL, on every macOS XNotch supports.
        .package(url: "https://github.com/apple/swift-crypto", exact: "5.1.1")
    ],
    targets: [
        .target(name: "Walkie", dependencies: [
            .product(name: "XNotchKit", package: "Kit"),
            .product(name: "CryptoExtras", package: "swift-crypto")
        ]),
        .testTarget(name: "WalkieTests", dependencies: ["Walkie"])
    ]
)
