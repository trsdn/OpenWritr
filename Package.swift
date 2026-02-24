// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenWritr",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9")
    ],
    targets: [
        .executableTarget(
            name: "OpenWritr",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
