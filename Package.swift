// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DownloadManager",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "DownloadManagerBasic",
            targets: ["DownloadManagerBasic"]),
        .library(
            name: "HTTPChunkDownloadManager",
            targets: ["HTTPChunkDownloadManager"]),
        .library(
            name: "DownloadManager",
            targets: ["DownloadManager"]),
        .library(
            name: "DownloadManagerUI",
            targets: ["DownloadManagerUI"]),
    ],
    dependencies: [
        // 依赖项
        /// 日志代理
        .package(url: "https://github.com/enefry/LoggerProxy.git", from: "2.0.0"),
        /// 并发队列
        .package(url: "https://github.com/enefry/ConcurrencyCollection.git",from: "0.0.4"),
        /// 原子类型
        .package(url: "https://github.com/apple/swift-atomics", from: "1.3.0"),
    ],
    targets: [
        /// 基础类型声明
        .target(name: "DownloadManagerBasic",
                dependencies: [
                    .product(name: "ConcurrencyCollection",package: "ConcurrencyCollection"),
                    .product(name: "LoggerProxy",package: "LoggerProxy"),
                ],
                path: "Sources/DownloadManagerBasic"
        ),
        /// 基础http协议分块下载实现
        .target(
            name: "HTTPChunkDownloadManager",
            dependencies: [
                .target(name: "DownloadManagerBasic"),
                    .product(name: "ConcurrencyCollection",package: "ConcurrencyCollection"),
                    .product(name: "LoggerProxy",package: "LoggerProxy"),
                    .product(name: "Atomics",package: "swift-atomics")
                ],
            path: "Sources/HTTPChunkDownloadManager"
        ),
        /// 下载管理器，多任务，多类型下载
        .target(
            name: "DownloadManager",
            dependencies: [
                .target(name: "DownloadManagerBasic"),
                .product(name: "ConcurrencyCollection",package: "ConcurrencyCollection"),
                .product(name: "LoggerProxy",package: "LoggerProxy"),
                .product(name: "Atomics",package: "swift-atomics")
            ],
            path: "Sources/DownloadManager"
        ),
        .target(name: "DownloadManager_HTTPDownloader",
                dependencies: [
                    .target(name: "DownloadManagerBasic"),
                    .target(name: "DownloadManager"),
                    .target(name: "HTTPChunkDownloadManager"),
                ],
                path: "Sources/DownloadManager_HTTPDownloader"
               ),
        .target(
            name: "DownloadManagerUI",
            dependencies: [
                .target(name: "DownloadManagerBasic"),
                .target(name: "DownloadManager"),
                .target(name: "HTTPChunkDownloadManager"),
                .target(name: "DownloadManager_HTTPDownloader"),
                .product(name: "ConcurrencyCollection",package: "ConcurrencyCollection"),
                .product(name: "LoggerProxy",package: "LoggerProxy"),
                .product(name: "Atomics",package: "swift-atomics"),
            ],
            path: "UI"
        ),
        .testTarget(
            name: "DownloadManagerTests",
            dependencies: ["DownloadManager"]
        )
    ]
)
