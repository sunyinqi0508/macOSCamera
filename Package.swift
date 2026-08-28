// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "mbCamera",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CameraCore", targets: ["CameraCore"]),
        .executable(name: "mbCamera", targets: ["mbCamera"])
    ],
    targets: [
        .target(
            name: "CameraCore"
        ),
        .executableTarget(
            name: "mbCamera",
            dependencies: ["CameraCore"]
        ),
        .testTarget(
            name: "CameraCoreTests",
            dependencies: ["CameraCore"]
        ),
        .testTarget(
            name: "mbCameraTests",
            dependencies: ["mbCamera", "CameraCore"]
        )
    ]
)
