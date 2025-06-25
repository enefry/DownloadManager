import Foundation

/// 下载管理器配置协议
public struct DownloadManagerConfiguration: Sendable {
    /// 自定义实现
    public struct FeatureImplements: Sendable {
        /// 支持外置 HTTPChunkDownloadManager
        public var downloaderFactoryCenter: DownloaderFactoryCenter
        /// 下载记录存储
        public let downloadPersistenceFactory: @Sendable () -> DownloadPersistenceManagerProtocol
        /// 网络监控
        public let networkMonitorFactory: @Sendable () -> NetworkMonitorProtocol

        public init(downloaderFactoryCenter: DownloaderFactoryCenter? = nil, downloadPersistenceFactory: (@Sendable () -> DownloadPersistenceManagerProtocol)? = nil, networkMonitorFactory: (@Sendable () -> NetworkMonitorProtocol)? = nil) {
            self.downloaderFactoryCenter = downloaderFactoryCenter ?? DownloaderFactoryCenter.shared
            self.downloadPersistenceFactory = downloadPersistenceFactory ?? { DownloadPersistenceManager() }
            self.networkMonitorFactory = networkMonitorFactory ?? { NetworkMonitor() }
        }
    }

    public let name: String
    /// 最大并发下载数
    public var maxConcurrentDownloads: Int = 4
    /// 默认任务配置
    public var defaultTaskConfiguration = DownloadTaskConfiguration()
    /// 是否在 WiFi 网络下自动恢复下载
    public var autoResumeOnWifi: Bool = true
    /// 是否在蜂窝网络下自动暂停下载
    public var autoPauseOnCellular: Bool = true

    public let featureImplements: FeatureImplements

    public init(name: String = "", maxConcurrentDownloads: Int = 4, defaultTaskConfiguration: DownloadTaskConfiguration = DownloadTaskConfiguration(), autoResumeOnWifi: Bool = true, autoPauseOnCellular: Bool = false, featureImplements: FeatureImplements? = nil) {
        self.name = name
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.defaultTaskConfiguration = defaultTaskConfiguration
        self.autoResumeOnWifi = autoResumeOnWifi
        self.autoPauseOnCellular = autoPauseOnCellular
        self.featureImplements = featureImplements ?? FeatureImplements()
    }
}
