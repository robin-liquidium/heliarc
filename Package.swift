// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Heliarc",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Heliarc", targets: ["Heliarc"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "HeliarcCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Heliarc",
            dependencies: [
                "HeliarcCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .testTarget(
            name: "HeliarcCoreTests",
            dependencies: ["HeliarcCore"]
        ),
    ]
)
