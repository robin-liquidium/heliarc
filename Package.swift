// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Heliarc",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Heliarc", targets: ["Heliarc"]),
    ],
    targets: [
        .target(name: "HeliarcCore"),
        .executableTarget(
            name: "Heliarc",
            dependencies: ["HeliarcCore"]
        ),
        .testTarget(
            name: "HeliarcCoreTests",
            dependencies: ["HeliarcCore"]
        ),
    ]
)
