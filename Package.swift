// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ApexControl",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ApexKit", targets: ["ApexKit"]),
        .executable(name: "apexctl", targets: ["apexctl"]),
        .executable(name: "ApexControlApp", targets: ["ApexControlApp"]),
    ],
    targets: [
        .target(
            name: "ApexKit"
        ),
        .executableTarget(
            name: "apexctl",
            dependencies: ["ApexKit"]
        ),
        .executableTarget(
            name: "ApexControlApp",
            dependencies: ["ApexKit"]
        ),
        .testTarget(
            name: "ApexKitTests",
            dependencies: ["ApexKit"]
        ),
    ]
)
