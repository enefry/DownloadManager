import Combine
import ConcurrencyCollection
import Foundation

/// 下载管理器协议
public protocol DownloadManagerProtocol: AnyObject {
    /// 获取所有下载任务
    var allTasks: [any DownloadTaskProtocol] { get }

    /// 活动下载任务数量
    var activeTaskCount: Int { get }

    /// 最大并发下载数
    var maxConcurrentDownloads: Int { get set }

    /// 活动任务数量变化发布者
    var activeTaskCountPublisher: AnyPublisher<Int, Never> { get }

    /// 创建新的下载任务
    /// - Parameters:
    ///   - url: 下载URL，重复url只会映射到同一个task
    ///   - destination: 目标保存路径
    ///   - configuration: 下载配置
    /// - Returns: 下载任务
    func download(url: URL, destination: URL, configuration: DownloadTaskConfiguration?) -> DownloadTaskProtocol

    /// 获取指定ID的下载任务
    /// - Parameter identifier: 任务ID
    /// - Returns: 下载任务，如果不存在则返回nil
    func task(withIdentifier identifier: String) -> DownloadTaskProtocol?

    /// 获取指定ID的下载任务
    /// - Parameter url: 任务的URL
    /// - Returns: 下载任务，如果不存在则返回nil
    func task(withURL url: URL) -> DownloadTaskProtocol?

    /// 删除指定ID的下载任务
    /// - Parameter identifier: 任务ID
    func removeTask(withIdentifier identifier: String)

    /// 删除指定ID的下载任务
    /// - Parameter url: 任务的URL
    func removeTask(withURL url: URL)

    // MARK: - Task 操作

    // 暂停任务
    func pause(task: DownloadTaskProtocol)
    // 暂停任务
    func pause(withIdentifier: String)
    /// 恢复任务
    func resume(task: DownloadTaskProtocol)
    /// 恢复任务
    func resume(withIdentifier: String)

    /// 停止任务
    func cancel(task: DownloadTaskProtocol)
    /// 停止任务
    func cancel(withIdentifier: String)

    /// 删除任务
    func remove(task: DownloadTaskProtocol)
    /// 删除任务
    func remove(withIdentifier: String)

    /// 插入优先任务
    func insert(task: DownloadTaskProtocol)
    func insert(withIdentifier: String)

    // MARK: - 批量操作

    /// 暂停所有下载任务
    func pauseAll()

    /// 恢复所有下载任务
    func resumeAll()

    /// 取消所有下载任务
    func cancelAll()

    /// 删除所有完成的下载任务
    func removeAllFinish()

    /// 删除所有下载任务和文件
    func removeAll()

    /// 等待所有任务完成
    /// - Throws: 下载过程中的错误
    func waitForAllTasks() async throws
}
