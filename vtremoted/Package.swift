// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "vtremoted",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "VTRemotedCore", targets: ["VTRemotedCore"]),
        .executable(name: "vtremoted", targets: ["vtremoted"])
    ],
    targets: [
        .systemLibrary(
            name: "CLZ4",
            path: "Sources/CLZ4",
            pkgConfig: "liblz4",
            providers: [
                .brew(["lz4"]),
                .apt(["liblz4-dev"])
            ]
        ),
        .target(
            name: "VTRemotedCore",
            dependencies: ["CLZ4"],
            path: "Sources/VTRemotedCore",
            swiftSettings: [
                .define("VTR_SWIFT_PACKAGE")
            ]
        ),
        .executableTarget(
            name: "vtremoted",
            dependencies: ["VTRemotedCore"],
            path: "Sources/vtremoted",
            swiftSettings: [
                .define("VTR_SWIFT_PACKAGE")
            ]
        ),
        .testTarget(
            name: "VTRemotedCoreTests",
            dependencies: ["VTRemotedCore"],
            path: "Tests/VTRemotedCoreTests"
        )
    ]
)
