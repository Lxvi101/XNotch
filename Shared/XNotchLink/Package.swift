// swift-tools-version:5.9
import PackageDescription

// The local link between XNotch on a Mac and its iPhone and iPad companion.
let package = Package(
    name: "XNotchLink",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "XNotchLink", targets: ["XNotchLink"])
    ],
    targets: [
        .target(name: "XNotchLink"),
        .testTarget(name: "XNotchLinkTests", dependencies: ["XNotchLink"])
    ]
)
