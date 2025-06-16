// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "DownloadManager",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "DownloadManager",
            targets: ["DownloadManager"]),
    ],
    dependencies: [
        // 依赖项
        .package(url: "https://github.com/enefry/LoggerProxy.git", from: "2.0.0"),
        .package(url: "https://github.com/enefry/ConcurrencyCollection.git",from: "0.0.4"),
        .package(url: "https://github.com/apple/swift-atomics", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "DownloadManager",
            dependencies: [
                .productItem(name: "ConcurrencyCollection",package: "ConcurrencyCollection"),
                .productItem(name: "LoggerProxy",package: "LoggerProxy"),
                .productItem(name: "Atomics",package: "swift-atomics")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "DownloadManagerTests",
            dependencies: ["DownloadManager"],
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
