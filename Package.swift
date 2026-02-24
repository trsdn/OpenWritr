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
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "OpenWritr",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "ObjCExceptionCatcher"
            ],
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
