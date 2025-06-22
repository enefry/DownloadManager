import Foundation

/// 下载管理器配置协议
public struct DownloadManagerConfiguration {
    public let name: String
    /// 最大并发下载数
    public var maxConcurrentDownloads: Int = 4
    /// 默认任务配置
    public var defaultTaskConfiguration = DownloadTaskConfiguration()
    /// 是否在 WiFi 网络下自动恢复下载
    public var autoResumeOnWifi: Bool = true
    /// 是否在蜂窝网络下自动暂停下载
    public var autoPauseOnCellular: Bool = true

    /// 支持外置 ChunkDownloadManager
    public var chunkDownloadManagerFactory: ((_ downloadTask: DownloadTask, _ configuration: ChunkConfiguration, _ delegate: ChunkDownloadManagerDelegate) -> any ChunkDownloadManagerProtocol)?
    /// 下载记录存储
    public var downloadPersistenceFactory: (() -> DownloadPersistenceManagerProtocol)?
    /// 网络监控
    public var networkMonitorFactory: (() -> NetworkMonitorProtocol)?

    public init(name: String = "", maxConcurrentDownloads: Int = 4, defaultTaskConfiguration: DownloadTaskConfiguration = DownloadTaskConfiguration(), autoResumeOnWifi: Bool = true, autoPauseOnCellular: Bool = false, chunkDownloadManagerFactory: ((_: DownloadTask, _: ChunkConfiguration, _: ChunkDownloadManagerDelegate) -> any ChunkDownloadManagerProtocol)? = nil, downloadPersistenceFactory: (() -> DownloadPersistenceManagerProtocol)? = nil, networkMonitorFactory: (() -> NetworkMonitorProtocol)? = nil) {
        self.name = name
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.defaultTaskConfiguration = defaultTaskConfiguration
        self.autoResumeOnWifi = autoResumeOnWifi
        self.autoPauseOnCellular = autoPauseOnCellular
        self.chunkDownloadManagerFactory = chunkDownloadManagerFactory
        self.downloadPersistenceFactory = downloadPersistenceFactory
        self.networkMonitorFactory = networkMonitorFactory
    }
}
