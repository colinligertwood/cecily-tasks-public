// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TasksCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "TasksCore", targets: ["TasksCore"])
    ],
    targets: [
        .target(name: "TasksCore"),
        .testTarget(name: "TasksCoreTests", dependencies: ["TasksCore"]),
    ]
)
