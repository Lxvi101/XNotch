// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "XNotchKit",
    platforms: [.macOS(.v14)],
    products: [
        // Dynamic, so XNotch and every extension share one copy of the kit's
        // types. A static copy inside an extension gives the same type two
        // metadata records and every cast between them fails.
        .library(name: "XNotchKit", type: .dynamic, targets: ["XNotchKit"])
    ],
    targets: [
        .target(name: "XNotchKit")
    ]
)
