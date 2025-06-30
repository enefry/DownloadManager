import Atomics
import Combine
import ConcurrencyCollection
import DownloadManagerBasic
import Foundation
import LoggerProxy

fileprivate let kLogTag = "DM.DM"

// MARK: - DownloadManager State

/// 下载管理器的公共接口，作为客户端与 Actor 交互的桥梁
public final class DownloadManager: DownloadManagerProtocol, @unchecked Sendable {
    // MARK: - Public Properties

    @Published var startup: Bool
    /// 管理器公开的状态对象，通过 ObservableObject 模式发布
    public let state: DownloadManagerState

    /// 与 DownloadManagerActor 交互的引用
    private let actor: DownloadManagerActor

    // Combine Publishers 用于订阅状态变化
    public var activeTaskCountPublisher: AnyPublisher<Int, Never>

    public var allTasksPublisher: AnyPublisher<[any DownloadTaskProtocol], Never>
    public var progressPublisher: AnyPublisher<DownloadProgress, Never>
    public var speedPublisher: AnyPublisher<DownloadManagerSpeed, Never>
    public var stateChangedPublisher: AnyPublisher<(any DownloadTaskProtocol, TaskState), Never>

    // 同步获取所有任务列表
    public var allTasks: [any DownloadTaskProtocol] {
        // 直接从状态中获取，因为状态由 Actor 异步更新
        state.allTasks
    }

    // 同步获取活跃任务数量
    public var activeTaskCount: Int {
        state.activeTaskCount
    }

    // 同步获取和设置最大并发下载数
    public var maxConcurrentDownloads: Int {
        get { state.maxConcurrentDownloads }
        set {
            let newValue = newValue
            let actor = self.actor
            // 设置操作异步转发给 Actor
            Task {
                await actor.setMaxConcurrentDownloads(newValue)
            }
        }
    }

    private var cancellables = Set<AnyCancellable>() // 用于管理 Combine 订阅

    // MARK: - Initialization

    /// 初始化 DownloadManager
    /// - Parameter configuration: 下载管理器的配置
    init(configuration: DownloadManagerConfiguration) {
        let state = DownloadManagerState()
        let actor = DownloadManagerActor(configuration: configuration)
        self.actor = actor
        self.state = state
//        allTaskPublisher = state.$allTasks.map({ $0.map({ $0 as DownloadTaskProtocol }) }).eraseToAnyPublisher()
        activeTaskCountPublisher = state.$activeTaskCount.eraseToAnyPublisher()
        allTasksPublisher = state.$allTasks.map({ $0.map({ $0 as DownloadTaskProtocol }) }).eraseToAnyPublisher()
        speedPublisher = state.$speed.eraseToAnyPublisher()
        stateChangedPublisher = state.taskStateNotify.eraseToAnyPublisher()
        progressPublisher = state.$progress.eraseToAnyPublisher()

        startup = false
        // 将状态更新的闭包传递给 Actor，以便 Actor 可以通知 DownloadManager 更新公共状态
        Task { [weak self] in
            guard let self = self else {
                return
            }
            try? await actor.setup()
            await actor.setStateUpdateHandler { [weak self] in
                guard let self = self else {
                    return
                }
                await self.updateStateFromActor()
            }
            await actor.setTaskStateChangeHandler { [weak self] tuple in
                guard let self = self else {
                    return
                }
                await self.state.sendNotify(taskState: tuple)
            }
            await actor.setSpeedUpdateHandler { [weak self] speed in
                await self?.onUpdate(speed: speed)
            }
            await actor.setProgressUpdateHandler { [weak self] progress in
                await self?.onUpdate(progress: progress)
            }
            self.startup = true
        }
        LoggerProxy.ILog(tag: kLogTag, msg: "DownloadManager initialized")
    }

    @MainActor
    func onUpdate(progress: DownloadProgress) async {
        await state.update(progress: progress)
    }

    @MainActor
    func onUpdate(speed: DownloadManagerSpeed) async {
        await state.update(speed: speed)
    }

    public func waitForStartup() async {
        var event = [AnyCancellable]()
        if startup {
            return
        }
        await withUnsafeContinuation { cc in
            $startup.filter({ $0 }).sink { _ in
                cc.resume(returning: ())
            }.store(in: &event)
        }
        event.removeAll()
    }

    /// Deinitialization
    deinit {
        LoggerProxy.ILog(tag: kLogTag, msg: "DownloadManager deinitialized")
        cancellables.forEach { $0.cancel() } // 取消所有 Combine 订阅
        let actor = actor
        Task {
            try? await actor.stopAllTasks()
        }
    }

    // MARK: - State Synchronization

    /// 从 Actor 同步最新的状态到 DownloadManagerState
    @MainActor
    private func updateStateFromActor() async {
        let tasks = await actor.getAllTasks()
        let activeCount = await actor.getActiveTaskCount()
        let maxConcurrent = await actor.getMaxConcurrentDownloads()

        // 在主线程更新 @Published 属性
        state.updateAllTasks(tasks)
        state.updateActiveTaskCount(activeCount)
        state.updateMaxConcurrentDownloads(maxConcurrent)
    }

    // MARK: - Public Task Management Methods (Non-async)

    /// 创建并开始一个下载任务。此方法会立即返回一个 DownloadTaskProtocol 实例。
    /// - Parameters:
    ///   - url: 下载源 URL
    ///   - destination: 下载目标 URL
    ///   - configuration: 任务的特定配置 (可选)
    /// - Returns: 创建或已存在的 DownloadTask 实例
    public func download(url: URL, destination: URL, configuration: DownloadTaskConfiguration? = nil, completion: ((any DownloadTaskProtocol) -> Void)?) {
        Task {
            let task = await download(url: url, destination: destination, configuration: configuration)
            completion?(task)
        }
    }

    public func download(url: URL, destination: URL, configuration: DownloadTaskConfiguration?) async -> any DownloadTaskProtocol {
        let identifier = DownloadTask.buildIdentifier(url: url, destinationURL: destination)
        // 尝试立即返回已存在的任务，以实现同步接口
        if let existingTask = state.allTasks.first(where: { $0.identifier == identifier }) {
            LoggerProxy.DLog(tag: kLogTag, msg: "Returning existing task for download: \(identifier)")
            return existingTask
        }
        // 异步在 Actor 中创建和管理实际任务
        let task = await actor.createDownloadTask(url: url, destination: destination, configuration: configuration)
        LoggerProxy.DLog(tag: kLogTag, msg: "Created temp task and started actor creation for: \(identifier)")
        return task
    }

//    public func downl

    /// 暂停指定的下载任务
    /// - Parameter task: 要暂停的任务实例
    public func pause(task: any DownloadTaskProtocol) {
        pause(withIdentifier: task.identifier)
    }

    /// 暂停指定标识符的下载任务
    /// - Parameter identifier: 任务的唯一标识符
    public func pause(withIdentifier identifier: String) {
        Task {
            await actor.pauseTask(withIdentifier: identifier)
        }
    }

    /// 恢复指定的下载任务
    /// - Parameter task: 要恢复的任务实例
    public func resume(task: any DownloadTaskProtocol) {
        resume(withIdentifier: task.identifier)
    }

    /// 恢复指定标识符的下载任务
    /// - Parameter identifier: 任务的唯一标识符
    public func resume(withIdentifier identifier: String) {
        Task {
            await actor.resumeTask(withIdentifier: identifier)
        }
    }

    /// 取消指定的下载任务
    /// - Parameter task: 要取消的任务实例
    public func cancel(task: any DownloadTaskProtocol) {
        cancel(withIdentifier: task.identifier)
    }

    /// 取消指定标识符的下载任务
    /// - Parameter identifier: 任务的唯一标识符
    public func cancel(withIdentifier identifier: String) {
        Task {
            await actor.stopTask(withIdentifier: identifier, cleanupFile: false)
        }
    }

    /// 移除指定 URL 的下载任务
    /// - Parameter url: 任务的 URL
    public func remove(withURL url: URL) {
        if let task = task(withURL: url) {
            remove(withIdentifier: task.identifier)
        } else {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task with URL \(url) not found for removal.")
        }
    }

    /// 移除指定的下载任务
    /// - Parameter task: 要移除的任务实例
    public func remove(task: any DownloadTaskProtocol) {
        remove(withIdentifier: task.identifier)
    }

    /// 移除指定标识符的下载任务
    /// - Parameter identifier: 任务的唯一标识符
    public func remove(withIdentifier identifier: String) {
        Task {
            await actor.removeTask(withIdentifier: identifier, cleanupFile: true)
        }
    }

    /// 将指定的下载任务插入到下载队列的最前端（高优先级）
    /// - Parameter task: 要插入的任务实例
    public func insert(task: any DownloadTaskProtocol) {
        insert(withIdentifier: task.identifier)
    }

    /// 将指定标识符的下载任务插入到下载队列的最前端（高优先级）
    /// - Parameter identifier: 任务的唯一标识符
    public func insert(withIdentifier identifier: String) {
        Task {
            await actor.insertTaskAtFront(withIdentifier: identifier)
        }
    }

    /// 重新优先任务
    /// - Parameter task: 任务
    public func restart(task: any DownloadTaskProtocol) {
        restart(withIdentifier: task.identifier)
    }

    /// 插入优先任务
    /// - Parameter identifier: 任务ID
    public func restart(withIdentifier identifier: String) {
        Task {
            await actor.restart(withIdentifier: identifier)
        }
    }

    // MARK: - Batch Operations (Non-async)

    /// 暂停所有下载任务
    public func pauseAll() {
        Task {
            await actor.pauseAllTasks()
        }
    }

    /// 恢复所有可恢复的下载任务
    public func resumeAll() {
        Task {
            await actor.resumeAllTasks()
        }
    }

    /// 取消所有下载任务
    public func cancelAll() {
        Task {
            try? await actor.stopAllTasks()
        }
    }

    /// 移除所有已完成（成功或失败）的任务
    public func removeAllFinished() {
        Task {
            await actor.removeAllFinishedTasks()
        }
    }

    /// 移除所有任务
    public func removeAll() {
        Task {
            await actor.removeAllTasks()
        }
    }

    // MARK: - Task Query Methods (Synchronous access to published state)

    /// 根据标识符查询任务
    /// - Parameter identifier: 任务的唯一标识符
    /// - Returns: 对应的 DownloadTaskProtocol 实例 (可选)
    public func task(withIdentifier identifier: String) -> (any DownloadTaskProtocol)? {
        return state.allTasks.first { $0.identifier == identifier }
    }

    /// 根据 URL 查询任务
    /// - Parameter url: 任务的 URL
    /// - Returns: 对应的 DownloadTaskProtocol 实例 (可选)
    public func task(withURL url: URL) -> (any DownloadTaskProtocol)? {
        return state.allTasks.first { $0.url == url }
    }

    // MARK: - Async Wait Method

    /// 异步等待所有活跃任务完成
    public func waitForAllTasks() async throws {
        try await actor.waitForAllTasks()
    }
}
