// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenWritr",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
        .package(url: "https://github.com/mxcl/AppUpdater.git", from: "4.1.2")
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
                .product(name: "AppUpdater", package: "AppUpdater"),
                "ObjCExceptionCatcher"
            ],
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "OpenWritrTests",
            dependencies: ["OpenWritr"]
        )
    ]
)
