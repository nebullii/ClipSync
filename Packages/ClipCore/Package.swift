// swift-tools-version:5.9
// Tools version 5.9 => every target compiles in Swift language mode 5,
// even when built with the Swift 6 toolchain shipped in Xcode 16+.
import PackageDescription

let package = Package(
    name: "ClipCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "ClipCore", targets: ["ClipCore"])
    ],
    targets: [
        .target(
            name: "ClipCore",
            path: "Sources/ClipCore"
        ),
        .testTarget(
            name: "ClipCoreTests",
            dependencies: ["ClipCore"],
            path: "Tests/ClipCoreTests"
        )
    ]
)
