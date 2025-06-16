import Combine
import Foundation

/// 下载任务协议
public protocol DownloadTaskProtocol: AnyObject {
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

    /// 进度发布者
    var progressPublisher: AnyPublisher<Double, Never> { get }

    /// 状态发布者
    var statePublisher: AnyPublisher<DownloadState, Never> { get }

    /// 下载速度发布者
    var speedPublisher: AnyPublisher<Double, Never> { get }
}
