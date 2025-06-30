import Combine
import ConcurrencyCollection
import DownloadManagerBasic
import Foundation

/// 速度记录
public struct DownloadManagerSpeed: Codable, Sendable, Hashable, Equatable {
    /// 当前下载速度
    public let speed: Double
    /// 预计剩余时长
    public let remainingTime: TimeInterval
    public init(speed: Double, remainingTime: TimeInterval) {
        self.speed = speed
        self.remainingTime = remainingTime
    }
}

/// 下载管理器协议
public protocol DownloadManagerProtocol {
    /// 获取所有下载任务
    var allTasks: [any DownloadTaskProtocol] { get }
    // 所有任务变化发布者
    var allTasksPublisher: AnyPublisher<[any DownloadTaskProtocol], Never> { get }
    /// 活动下载任务数量
    var activeTaskCount: Int { get }
    /// 活动任务数量变化发布者
    var activeTaskCountPublisher: AnyPublisher<Int, Never> { get }
    /// 全局速度发布者
    var progressPublisher: AnyPublisher<DownloadProgress, Never> { get }
    /// 全局速度发布者
    var speedPublisher: AnyPublisher<DownloadManagerSpeed, Never> { get }

    /// 最大并发下载数
    var maxConcurrentDownloads: Int { get set }

    /// 创建新的下载任务
    /// - Parameters:
    ///   - url: 下载URL，重复url只会映射到同一个task
    ///   - destination: 目标保存路径
    ///   - configuration: 下载配置
    /// - Returns: 下载任务
    @discardableResult
    func download(url: URL, destination: URL, configuration: DownloadTaskConfiguration?) async -> DownloadTaskProtocol

    @discardableResult
    func download(url: URL, destination: URL, configuration: DownloadTaskConfiguration?, completion: ((any DownloadTaskProtocol) -> Void)?)

    /// 获取指定ID的下载任务
    /// - Parameter identifier: 任务ID
    /// - Returns: 下载任务，如果不存在则返回nil
    func task(withIdentifier identifier: String) -> DownloadTaskProtocol?

    /// 获取指定ID的下载任务
    /// - Parameter url: 任务的URL
    /// - Returns: 下载任务，如果不存在则返回nil
    func task(withURL url: URL) -> DownloadTaskProtocol?

    // 暂停任务
    /// - Parameter task: 任务
    func pause(task: DownloadTaskProtocol)
    // 暂停任务
    /// - Parameter identifier: 任务ID
    func pause(withIdentifier: String)
    /// 恢复任务
    /// - Parameter task: 任务
    func resume(task: DownloadTaskProtocol)
    /// 恢复任务
    /// - Parameter identifier: 任务ID
    func resume(withIdentifier: String)
    /// 停止任务
    /// - Parameter task: 任务
    func cancel(task: DownloadTaskProtocol)
    /// 停止任务
    /// - Parameter identifier: 任务ID
    func cancel(withIdentifier: String)
    /// 删除任务
    /// - Parameter task: 任务
    func remove(task: DownloadTaskProtocol)
    /// 删除指定ID的下载任务
    /// - Parameter identifier: 任务ID
    func remove(withIdentifier identifier: String)
    /// 插入优先任务
    /// - Parameter task: 任务
    func insert(task: DownloadTaskProtocol)
    /// 插入优先任务
    /// - Parameter identifier: 任务ID
    func insert(withIdentifier: String)
    /// 重新优先任务
    /// - Parameter task: 任务
    func restart(task: DownloadTaskProtocol)
    /// 插入优先任务
    /// - Parameter identifier: 任务ID
    func restart(withIdentifier: String)

    // MARK: - 批量操作

    /// 暂停所有下载任务
    func pauseAll()

    /// 恢复所有下载任务
    func resumeAll()

    /// 取消所有下载任务
    func cancelAll()

    /// 删除所有完成的下载任务
    func removeAllFinished()

    /// 删除所有下载任务和文件
    func removeAll()

    /// 等待所有任务完成
    /// - Throws: 下载过程中的错误
    func waitForAllTasks() async throws

    /// 初始化后等待启动
    func waitForStartup() async
}

public func CreateDownloadManager(withConfigure configure: DownloadManagerConfiguration? = nil) -> DownloadManagerProtocol {
    let configure = configure ?? DownloadManagerConfiguration()
    return DownloadManager(configuration: configure)
}
