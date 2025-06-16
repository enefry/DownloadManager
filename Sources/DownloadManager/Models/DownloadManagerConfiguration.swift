import Foundation

/// 下载管理器配置协议
public struct DownloadManagerConfiguration {
    /// 最大并发下载数
    var maxConcurrentDownloads: Int = 4

    /// 默认任务配置
    var defaultTaskConfiguration = DownloadTaskConfiguration()

    /// 是否允许使用蜂窝网络下载
    var allowCellularDownloads: Bool = true

    /// 是否在 WiFi 网络下自动恢复下载
    var autoResumeOnWifi: Bool = true

    /// 是否在蜂窝网络下自动暂停下载
    var autoPauseOnCellular: Bool = true
}
