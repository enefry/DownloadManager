import Combine
import Foundation

public struct DownloadProgress {
    /// 记录时间
    public let timestamp: TimeInterval
    /// 已经下载大小
    public let downloadedBytes: Int64
    /// 总大小，对于未知下子大小，这个值为-1
    public let totalBytes: Int64
    init(timestamp: TimeInterval = Date.now.timeIntervalSince1970, downloadedBytes: Int64, totalBytes: Int64) {
        self.timestamp = timestamp
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
    }
}

/// 下载任务协议
public protocol DownloadTaskProtocol: AnyObject, Sendable {
    /// 下载任务的唯一标识符
    var identifier: String { get }

    /// 下载任务配置
    var taskConfigure: DownloadTaskConfiguration { get }

    /// 下载URL
    var url: URL { get }

    /// 目标保存路径
    var destinationURL: URL { get }

    /// 已下载字节数
    var downloadedBytes: Int64 { get }

    /// 总字节数
    var totalBytes: Int64 { get }

    /// 开始下载时间
    var startTime: TimeInterval { get }

    /// 当前状态
    var state: DownloadState { get }

    /// 当前进度
    var progress: DownloadProgress { get }

    /// 进度发布者
    var progressPublisher: AnyPublisher<DownloadProgress, Never> { get }

    /// 状态发布者
    var statePublisher: AnyPublisher<DownloadState, Never> { get }
}
