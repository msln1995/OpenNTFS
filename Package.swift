// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenNTFS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenNTFSCore", targets: ["OpenNTFSCore"]),
        .executable(name: "openntfs", targets: ["OpenNTFSCLI"]),
        .executable(name: "openntfs-selftest", targets: ["OpenNTFSSelfTest"]),
        .executable(name: "OpenNTFSApp", targets: ["OpenNTFSApp"]),
    ],
    targets: [
        .target(name: "OpenNTFSCore"),
        .executableTarget(name: "OpenNTFSCLI", dependencies: ["OpenNTFSCore"]),
        .executableTarget(name: "OpenNTFSSelfTest", dependencies: ["OpenNTFSCore"]),
        .executableTarget(name: "OpenNTFSApp", dependencies: ["OpenNTFSCore"]),
    ]
)
