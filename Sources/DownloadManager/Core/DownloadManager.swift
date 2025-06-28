import Atomics
import Combine
import ConcurrencyCollection
import DownloadManagerBasic
import Foundation
import LoggerProxy

fileprivate let kLogTag = "DownloadManager"

// MARK: - DownloadManager State

/// 下载管理器的公共状态，通过 Combine 发布，供 UI 或其他模块订阅
public final class DownloadManagerState: ObservableObject {
    /// 当前活跃（正在下载或准备下载）的任务数量
    @Published public private(set) var activeTaskCount: Int = 0
    /// 所有任务的列表，包括活跃、暂停、完成、失败等所有状态
    @Published public private(set) var allTasks: [DownloadTask] = []
    /// 最大并发下载数
    @Published public private(set) var maxConcurrentDownloads: Int = 4

    /// 更新活跃任务数量
    /// - Parameter count: 新的活跃任务数量
    func updateActiveTaskCount(_ count: Int) {
        if activeTaskCount != count {
            activeTaskCount = count
        }
    }

    /// 更新所有任务列表
    /// - Parameter tasks: 新的任务列表
    func updateAllTasks(_ tasks: [DownloadTask]) {
        if allTasks != tasks {
            allTasks = tasks
        }
    }

    /// 更新最大并发下载数
    /// - Parameter count: 新的最大并发下载数
    func updateMaxConcurrentDownloads(_ count: Int) {
        if maxConcurrentDownloads != count {
            maxConcurrentDownloads = count
        }
    }
}

// MARK: - Internal Download Manager Actor

/// 下载管理器的核心逻辑，使用 Actor 隔离并发访问
actor DownloadManagerActor {
    // MARK: - Properties

    /// 存储所有下载任务的字典，以 identifier 为键
    private var tasks: [String: DownloadTask] = [:]
    /// 维护任务的下载顺序，例如优先级队列或添加顺序
    private var taskOrder: [String] = []
    /// 存储每个下载任务对应的分片下载管理器
    private var chunkManagers: [String: any Downloader] = [:]
    /// 下载管理器的配置
    private var configuration: DownloadManagerConfiguration
    /// 用于持久化下载任务的管理器
    private let persistenceManager: DownloadPersistenceManagerProtocol
    /// 网络监控
    private let networkMonitor: NetworkMonitorProtocol
    /// Combine 订阅的持有者
    private var cancellables = Set<AnyCancellable>()

    /// 跟踪当前正在活跃下载的任务 ID 集合
    private var _activeTaskIds: Set<String> = []
    func activeTask(withIdentifier identifier: String) {
        _activeTaskIds.insert(identifier)
        if _activeTaskIds.count > 0,
           speedTimer == nil {
            setupSpeedTimer()
        }
    }

    func inactiveTask(withIdentifier identifier: String) {
        if let _ = _activeTaskIds.remove(identifier) {
            lastDownloadBytes[identifier] = nil
        }
        if _activeTaskIds.count == 0 {
            stopSpeedTimer()
        }
    }

    func removeAllActiveTasks() {
        _activeTaskIds.removeAll()
        lastDownloadBytes.removeAll()
        stopSpeedTimer()
    }

    func allActiveTask() -> [String] {
        return Array(_activeTaskIds)
    }

    func hasActiveTask(withIdentifier identifier: String) -> Bool {
        _activeTaskIds.contains(identifier)
    }

    /// 获取当前活跃任务的数量
    /// - Returns: 活跃任务的数量
    func getActiveTaskCount() -> Int {
        return _activeTaskIds.count
    }

    /// 状态更新的闭包，用于通知 DownloadManager 更新其公共状态
    private var stateUpdateHandler: (() async -> Void)?
    /// 速度更新的timer
    private var speedTimer: Task<Void, Never>?
    private var lastDownloadBytes: [String: (TimeInterval, Int64)] = [:]

    // MARK: - Initialization

    /// 初始化 DownloadManagerActor
    /// - Parameter configuration: 下载管理器的配置
    init(configuration: DownloadManagerConfiguration) {
        self.configuration = configuration
        persistenceManager = configuration.featureImplements.downloadPersistenceFactory()
        networkMonitor = configuration.featureImplements.networkMonitorFactory()
    }

    public func setup() async throws {
        await persistenceManager.setup(configure: configuration)
        try await loadPersistedTasks()
        await setupNetworkMonitoring()
        // 初始调度，以处理加载后的任务
        await scheduleNextDownloads()
    }

    func setupSpeedTimer() {
        speedTimer?.cancel()
        speedTimer = Task {
            let timer = Timer.publish(every: 1.0, on: .main, in: .common)
                .autoconnect()
                .values

            for await _ in timer {
                if Task.isCancelled { break }
                await self.onSpeedCalculate()
            }
        }
    }

    func stopSpeedTimer() {
        speedTimer?.cancel()
        speedTimer = nil
    }

    func onSpeedCalculate() async {
        let now = Date().timeIntervalSince1970
        for activeTaskId in allActiveTask() {
            if let task = tasks[activeTaskId] {
                if let last = lastDownloadBytes[activeTaskId] {
                    //
                    let cost = (now - last.0)
                    let bytes = (task.downloadedBytes - last.1)
                    if cost > 0 && bytes > 0 {
                        task.update(speed: Double(bytes) / cost)
                    }
                }
                lastDownloadBytes[activeTaskId] = (now, task.downloadedBytes)
            }
        }
    }

    func set(_ mgr: (any Downloader)?, for identifier: String) async {
        if let last = chunkManagers[identifier],
           last !== mgr {
            await last.cancel()
        }
        chunkManagers[identifier] = mgr
    }

    func getDownloader(_ identifier: String) -> (any Downloader)? {
        chunkManagers[identifier]
    }

    /// 设置状态更新处理器
    /// - Parameter handler: 用于更新 DownloadManager 公共状态的闭包
    func setStateUpdateHandler(_ handler: @escaping () async -> Void) {
        stateUpdateHandler = handler
    }

    /// Deinitialization
    deinit {
        LoggerProxy.ILog(tag: kLogTag, msg: "Cancelling all tasks and deinitializing DownloadManagerActor")

        // 取消所有正在进行的任务
        let chunkManagers = chunkManagers
        let persistenceManager = persistenceManager
        Task {
            for chunk in chunkManagers {
                await chunk.value.cancel()
            }
            try? await persistenceManager.clearTasks()
        }
        // 清理所有资源
        self.chunkManagers.removeAll()
        tasks.removeAll()
        taskOrder.removeAll()
        removeAllActiveTasks()
    }

    // MARK: - Private Setup Methods

    /// 从持久化存储加载任务
    private func loadPersistedTasks() async throws {
        let persistedTasks = try await persistenceManager.loadTasks()
        for task in persistedTasks {
            if task.state == .downloading {
                await task.update(state: .pending)
            }
            tasks[task.identifier] = task
            await task.update(progress: .init(downloadedBytes: task.downloadedBytes, totalBytes: task.totalBytes))
            taskOrder.append(task.identifier)
            LoggerProxy.DLog(tag: kLogTag, msg: "Loaded persisted task: \(task.identifier) with state \(task.state)")
        }
        LoggerProxy.DLog(tag: kLogTag, msg: "Loaded \(persistedTasks.count) persisted tasks")
        await notifyStateUpdate() // 通知外部状态已更新
    }

    /// 设置网络状态监控
    private func setupNetworkMonitoring() async {
        networkMonitor.statusPublisher.debounce(for: 0.2, scheduler: RunLoop.main)
            .sink { [weak self] status in
                // 在异步上下文中处理网络状态变化
                Task {
                    await self?.handleNetworkStateChange(status)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Interface Methods (Internal to Actor)

    /// 获取所有任务
    /// - Returns: 所有 DownloadTask 实例的数组
    func getAllTasks() -> [DownloadTask] {
        return taskOrder.compactMap { tasks[$0] }
    }

    /// 获取最大并发下载数
    /// - Returns: 最大并发下载数
    func getMaxConcurrentDownloads() -> Int {
        return configuration.maxConcurrentDownloads
    }

    /// 设置最大并发下载数
    /// - Parameter count: 新的最大并发下载数
    func setMaxConcurrentDownloads(_ count: Int) async {
        guard count > 0 else {
            LoggerProxy.WLog(tag: kLogTag, msg: "Max concurrent downloads must be greater than 0.")
            return
        }
        configuration.maxConcurrentDownloads = count
        LoggerProxy.ILog(tag: kLogTag, msg: "Max concurrent downloads set to \(count)")
        await scheduleNextDownloads() // 重新调度下载
        await notifyStateUpdate()
    }

    // MARK: - Task Management

    /// 创建并添加一个下载任务
    /// - Parameters:
    ///   - url: 下载源 URL
    ///   - destination: 下载目标 URL
    ///   - taskConfig: 任务的特定配置 (可选)
    /// - Returns: 创建的 DownloadTask 实例
    func createDownloadTask(url: URL, destination: URL, configuration taskConfig: DownloadTaskConfiguration?) async -> DownloadTask {
        let identifier = DownloadTask.buildIdentifier(url: url, destinationURL: destination)

        // 检查是否已存在
        if let existingTask = tasks[identifier] {
            LoggerProxy.DLog(tag: kLogTag, msg: "Task already exists: \(identifier), returning existing task.")
            return existingTask
        }

        let config = taskConfig ?? configuration.defaultTaskConfiguration
        let task = DownloadTask(
            url: url,
            destinationURL: destination,
            identifier: identifier,
            configuration: config
        )
        await task.update(state: .pending)
        await addNewTask(task)
        return task
    }

    private func canPause(_ state: TaskState) -> Bool {
        return state == .downloading || state == .pending
    }

    /// 暂停指定标识符的任务
    /// - Parameter identifier: 任务的唯一标识符
    func pauseTask(withIdentifier identifier: String) async {
        guard let task = tasks[identifier] else {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task not found for pause: \(identifier)")
            return
        }
        guard let mgr = getDownloader(task.identifier) else {
            if task.state == .downloading {
                await task.update(state: .paused)
                await notifyStateUpdate() // 通知外部状态已更新
                await scheduleNextDownloads() // 暂停后重新调度其他任务
            }
            LoggerProxy.WLog(tag: kLogTag, msg: "Task downloader not found: \(identifier)")
            return
        }

        if !canPause(task.state) {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task status is not downloading ,can not pause")
            return
        }
        await task.update(state: .paused)
        LoggerProxy.ILog(tag: kLogTag, msg: "Pausing task: \(identifier)")
        await mgr.pause()
        await notifyStateUpdate() // 通知外部状态已更新
        await scheduleNextDownloads() // 暂停后重新调度其他任务
    }

    private func canResume(_ task: DownloadTask) -> Bool {
        switch task.state {
        case .paused:
            return true
        default:
            return false
        }
    }

    /// 恢复指定标识符的任务
    /// - Parameter identifier: 任务的唯一标识符
    func resumeTask(withIdentifier identifier: String) async {
        guard let task = tasks[identifier] else {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task not found for resume: \(identifier)")
            return
        }

        guard let mgr = getDownloader(task.identifier) else {
            await task.update(state: .pending)
            await notifyStateUpdate() // 通知外部状态已更新
            await scheduleNextDownloads() // 暂停后重新调度其他任务
            return
        }

        if !canResume(task) {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task status is not pause, can not resume")
            return
        }
        LoggerProxy.ILog(tag: kLogTag, msg: "Resuming task: \(identifier)")
        await task.update(state: .pending) // 重新排队
        await notifyStateUpdate() // 通知外部状态已更新
        await scheduleNextDownloads() // 恢复后尝试启动下载
    }

    func canStop(_ state: TaskState) -> Bool {
        return state != .completed
    }

    /// 取消指定标识符的任务
    /// - Parameter identifier: 任务的唯一标识符
    func stopTask(withIdentifier identifier: String, cleanupFile: Bool) async {
        guard let task = tasks[identifier] else {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task not found for cancel: \(identifier)")
            return
        }
        if canStop(task.state) {
            await task.update(state: .stop)
        }
        guard let mgr = getDownloader(task.identifier) else {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task not found downloader for cancel: \(identifier)")
            return
        }

        LoggerProxy.ILog(tag: kLogTag, msg: "Cancelling task: \(identifier)")
        await mgr.cancel()
        await cleanupChunkManager(for: identifier, cleanupFile: cleanupFile) // 清理分片管理器
        await notifyStateUpdate() // 通知外部状态已更新
        await scheduleNextDownloads() // 取消后重新调度
    }

    /// 移除指定标识符的任务
    /// - Parameter identifier: 任务的唯一标识符
    /// - Parameter cleanup: 是否同时清理下载的临时文件
    func removeTask(withIdentifier identifier: String, cleanupFile: Bool) async {
        guard let task = tasks[identifier] else {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task not found for remove: \(identifier)")
            return
        }

        LoggerProxy.ILog(tag: kLogTag, msg: "Removing task: \(identifier)")

        // 如果任务正在下载或准备下载，先取消它
        if let mgr = getDownloader(task.identifier) {
            await mgr.cancel()
        }

        await removeTaskInternal(withIdentifier: identifier)
        await cleanupChunkManager(for: identifier, cleanupFile: cleanupFile)
        await notifyStateUpdate() // 通知外部状态已更新
        await scheduleNextDownloads() // 移除后重新调度
    }

    func restart(withIdentifier identifier: String) async {
        guard let task = tasks[identifier] else {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task not found for remove: \(identifier)")
            return
        }
        if case let .failed = task.state {
            await task.update(state: .pending)
            await notifyStateUpdate() // 通知外部状态已更新
            await scheduleNextDownloads() // 移除后重新调度
        }
    }

    /// 将指定标识符的任务插入到下载队列的最前端（高优先级）
    /// - Parameter identifier: 任务的唯一标识符
    func insertTaskAtFront(withIdentifier identifier: String) async {
        guard let task = tasks[identifier] else {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task not found for insert: \(identifier)")
            return
        }

        LoggerProxy.ILog(tag: kLogTag, msg: "Inserting task at front: \(identifier)")

        // 移除原位置并插入到前端
        taskOrder.removeAll { $0 == identifier }
        taskOrder.insert(identifier, at: 0)

        // 如果当前活跃任务已满，尝试暂停优先级较低的任务，为高优先级任务腾出位置
        if getActiveTaskCount() >= configuration.maxConcurrentDownloads {
            await pauseLeastPriorityActiveTask()
        }
        task.state
        // 尝试启动这个高优先级任务
        await startDownloadIfPossible(task)
        await saveTasks() // 保存任务顺序变化
        await notifyStateUpdate() // 通知外部状态已更新
    }

    // MARK: - Batch Operations

    /// 暂停所有下载任务
    func pauseAllTasks() async {
        LoggerProxy.ILog(tag: kLogTag, msg: "Pausing all tasks")
        for task in tasks.values {
            if canPause(task.state) {
                await task.update(state: .paused)
            }
            await getDownloader(task.identifier)?.pause()
        }
        await notifyStateUpdate() // 通知外部状态已更新
        await scheduleNextDownloads() // 暂停所有后，确保队列空闲
    }

    /// 恢复所有可恢复的下载任务
    func resumeAllTasks() async {
        LoggerProxy.ILog(tag: kLogTag, msg: "Resuming all tasks")

        for task in tasks.values {
            await getDownloader(task.identifier)?.resume()
        }
        await notifyStateUpdate() // 通知外部状态已更新
        await scheduleNextDownloads() // 恢复所有后，开始调度下载
    }

    /// 取消所有下载任务
    func stopAllTasks() async throws {
        LoggerProxy.ILog(tag: kLogTag, msg: "Cancelling all tasks")

        for task in tasks.values {
            if canStop(task.state) {
                await task.update(state: .stop)
            }
            await cleanupChunkManager(for: task.identifier, cleanupFile: false) // 清理每个任务的分片管理器
        }

        tasks.removeAll()
        taskOrder.removeAll()
        removeAllActiveTasks()
        try await persistenceManager.clearTasks() // 清除持久化数据
        await notifyStateUpdate() // 通知外部状态已更新
    }

    /// 移除所有已完成（成功或失败）的任务
    func removeAllFinishedTasks() async {
        LoggerProxy.ILog(tag: kLogTag, msg: "Removing all finished tasks")

        let finishedTaskIds = tasks.compactMap { key, task in
            task.state.isFinished ? key : nil
        }

        for taskId in finishedTaskIds {
            await cleanupChunkManager(for: taskId, cleanupFile: true)
            tasks.removeValue(forKey: taskId)
            taskOrder.removeAll { $0 == taskId }
            inactiveTask(withIdentifier: taskId) // 确保从活跃任务中移除
        }

        await saveTasks() // 保存任务列表变化
        await notifyStateUpdate() // 通知外部状态已更新
    }

    /// 移除所有任务
    func removeAllTasks() async {
        LoggerProxy.ILog(tag: kLogTag, msg: "Removing all tasks")

        // 彻底清理所有任务和资源
        for taskId in tasks.keys {
            await cleanupChunkManager(for: taskId, cleanupFile: true) // 确保所有分片管理器都被清理
        }
        tasks.removeAll()
        taskOrder.removeAll()
        removeAllActiveTasks()
        try? await persistenceManager.clearTasks() // 清除持久化数据
        await notifyStateUpdate() // 通知外部状态已更新
    }

    // MARK: - Task Query Methods

    /// 根据标识符获取任务
    /// - Parameter identifier: 任务的唯一标识符
    /// - Returns: 对应的 DownloadTask 实例 (可选)
    func getTask(withIdentifier identifier: String) -> DownloadTask? {
        return tasks[identifier]
    }

    /// 根据 URL 获取任务
    /// - Parameter url: 任务的 URL
    /// - Returns: 对应的 DownloadTask 实例 (可选)
    func getTask(withURL url: URL) -> DownloadTask? {
        return tasks.values.first { $0.url == url }
    }

    // MARK: - Wait for completion

    /// 等待所有活跃任务完成
    func waitForAllTasks() async throws {
        let activeTasks = tasks.values.filter { !$0.state.isFinished }

        guard !activeTasks.isEmpty else {
            LoggerProxy.DLog(tag: kLogTag, msg: "No active tasks to wait for.")
            return
        }

        LoggerProxy.ILog(tag: kLogTag, msg: "Waiting for \(activeTasks.count) active tasks to complete...")

        // 使用 TaskGroup 等待所有任务完成，任何一个任务失败则抛出错误
        return try await withThrowingTaskGroup(of: Void.self) { group in
            for task in activeTasks {
                group.addTask {
                    for await state in task.statePublisher.values {
                        if state.isFinished {
                            if case let .failed(error) = state {
                                throw error
                            }
                            break // 任务完成，退出循环
                        }
                    }
                }
            }
            try await group.waitForAll() // 等待所有任务完成
            LoggerProxy.ILog(tag: kLogTag, msg: "All active tasks completed.")
        }
    }

    // MARK: - Private Internal Methods

    /// 添加新任务到内部管理
    /// - Parameter task: 要添加的 DownloadTask 实例
    private func addNewTask(_ task: DownloadTask) async {
        tasks[task.identifier] = task
        taskOrder.append(task.identifier)
        await saveTasks() // 保存任务列表
        LoggerProxy.DLog(tag: kLogTag, msg: "Added new task: \(task.identifier)")
        await notifyStateUpdate() // 通知外部状态已更新
        // 尝试开始下载这个新任务
        await startDownloadIfPossible(task)
    }

    /// 从内部管理中移除任务
    /// - Parameter identifier: 要移除任务的唯一标识符
    private func removeTaskInternal(withIdentifier identifier: String) async {
        tasks.removeValue(forKey: identifier)
        taskOrder.removeAll { $0 == identifier }
        inactiveTask(withIdentifier: identifier) // 确保从活跃任务中移除
        await saveTasks()
        LoggerProxy.DLog(tag: kLogTag, msg: "Removed task internal: \(identifier)")
    }

    /// 判断任务是否可以开始下载
    /// - Parameter task: 要检查的任务
    /// - Returns: 如果任务可以开始下载，则为 true
//    private func canStartDownloading(task: DownloadTask) -> Bool {
//        // 如果已经有 ChunkManager 在运行，说明任务已在处理中，不能重复开始
//        if getDownloader(task.identifier) != nil {
//            return false
//        }
//
//        // 检查并发限制
//        if activeTaskIds.count >= configuration.maxConcurrentDownloads {
//            LoggerProxy.DLog(tag: kLogTag, msg: "Cannot start task \(task.identifier): Max concurrent downloads reached.")
//            return false
//        }
//
//        // 检查任务状态，只有在可以恢复或初始状态时才能开始
//        return task.state.canResume || task.state == .initialed
//    }

    /// 尝试启动一个下载任务，如果条件允许
    /// - Parameter task: 要启动的 DownloadTask 实例
    private func startDownloadIfPossible(_ task: DownloadTask) async {
        if task.state == .completed {
            return
        }
        /// 已经在下载的
        if let downloader = getDownloader(task.identifier),
           await downloader.state == .downloading {
            return
        }
        /// 并发检查
        if getActiveTaskCount() >= configuration.maxConcurrentDownloads {
            LoggerProxy.DLog(tag: kLogTag, msg: "Cannot start task \(task.identifier): Max concurrent downloads reached.")
            return
        }

        if let downloader = getDownloader(task.identifier),
           await downloader.state == .paused {
            /// 如果并发允许条件下，并且任务是暂停的, 恢复任务
            await downloader.resume()
            return
        }

        LoggerProxy.ILog(tag: kLogTag, msg: "Starting download for task: \(task.identifier)")
        guard let protocolType = task.downloadProtocol(),
              let chunkManager: any Downloader = await configuration.featureImplements.downloaderFactoryCenter.downloader(for: protocolType, task: task, delegate: self) else {
            LoggerProxy.ILog(tag: kLogTag, msg: "can't found downloader for \(task.identifier) ,url=\(task.url)")
            await task.update(state: .failed(DownloadError(code: -1, description: "无法创建下载器")))
            return
        }
        // 创建并设置分片下载管理器
        await task.update(state: .downloading)
        await set(chunkManager, for: task.identifier)
        activeTask(withIdentifier: task.identifier) // 将任务标记为活跃
        await chunkManager.start() // 启动任务
        await notifyStateUpdate() // 通知外部状态已更新
    }

    /// 调度下一次下载任务
    private func scheduleNextDownloads() async {
        let currentActive = getActiveTaskCount()
        let maxConcurrent = configuration.maxConcurrentDownloads

        LoggerProxy.DLog(tag: kLogTag, msg: "Scheduling downloads: Current active: \(currentActive), Max concurrent: \(maxConcurrent)")

        if currentActive > maxConcurrent {
            // 暂停多余的任务，从队列末尾的活跃任务开始暂停
            await pauseExcessTasks(excess: currentActive - maxConcurrent)
        } else if currentActive < maxConcurrent {
            // 启动等待中的任务，优先启动队列前端的任务
            await startWaitingTasks(slots: maxConcurrent - currentActive)
        }
        await notifyStateUpdate() // 通知外部状态已更新
    }

    /// 暂停超出并发限制的任务
    /// - Parameter excess: 需要暂停的任务数量
    private func pauseExcessTasks(excess: Int) async {
        var pausedCount = 0

        // 从 taskOrder 的末尾（通常是优先级较低或较晚添加的任务）开始遍历
        for taskId in taskOrder.reversed() {
            if pausedCount >= excess { break } // 已暂停足够数量的任务

            if let task = tasks[taskId],
               task.state == .downloading, // 确保任务正在下载中
               hasActiveTask(withIdentifier: taskId) { // 确保是活跃任务
                await getDownloader(taskId)?.pause()
                pausedCount += 1
                activeTask(withIdentifier: taskId) // 从活跃任务集合中移除
                LoggerProxy.DLog(tag: kLogTag, msg: "Paused excess task: \(taskId)")
            }
        }
    }

    /// 启动等待中的任务，填补空闲的下载槽位
    /// - Parameter slots: 可用的下载槽位数量
    private func startWaitingTasks(slots: Int) async {
        var startedCount = 0

        // 遍历任务顺序，从队列前端开始
        for taskId in taskOrder {
            if startedCount >= slots { break } // 已启动足够数量的任务

            if let task = tasks[taskId] {
                let state = task.state
                if !hasActiveTask(withIdentifier: taskId)
                    , state == .pending { // 确保任务当前不活跃
                    await startDownloadIfPossible(task)
                    startedCount += 1
                }
            }
        }
    }

    /// 暂停优先级最低的活跃任务（用于为新插入的高优先级任务腾出位置）
    private func pauseLeastPriorityActiveTask() async {
        // 从任务顺序的末尾开始找第一个活跃任务并暂停
        for taskId in taskOrder.reversed() {
            if let task = tasks[taskId],
               task.state == .downloading,
               hasActiveTask(withIdentifier: taskId) {
                await getDownloader(taskId)?.cancel()
                await set(nil, for: taskId)
                await task.update(state: .pending)
                inactiveTask(withIdentifier: taskId)
                LoggerProxy.DLog(tag: kLogTag, msg: "Paused least priority active task for priority insertion: \(taskId)")
                break
            }
        }
    }

    /// 清理指定任务的分片下载管理器
    /// - Parameter identifier: 任务的唯一标识符
    private func cleanupChunkManager(for identifier: String, cleanupFile: Bool) async {
        if let manager = getDownloader(identifier) {
            if cleanupFile {
                await manager.cleanup() // 执行分片管理器的清理操作
            }
            await set(nil, for: identifier)
        }
        inactiveTask(withIdentifier: identifier) // 确保从活跃任务集合中移除
        LoggerProxy.DLog(tag: kLogTag, msg: "Cleaned up chunk manager for: \(identifier)")
    }

    /// 处理任务状态变化
    /// - Parameters:
    ///   - task: 状态发生变化的 DownloadTask 实例
    ///   - state: 任务的最新状态
    private func handleTaskStateChange(task: DownloadTask, state: DownloaderState) async {
        LoggerProxy.DLog(tag: kLogTag, msg: "Task \(task.identifier) state changed to: \(state)")

        let finishedAct: (Bool) async -> Void = { cleanup in
            await self.cleanupChunkManager(for: task.identifier, cleanupFile: cleanup /* 完成才主动删除文件夹 */ ) // 清理资源
            self.inactiveTask(withIdentifier: task.identifier) // 从活跃任务集合中移除
            await self.scheduleNextDownloads() // 重新调度下一个下载
            await self.saveTasks() // 保存任务状态
        }

        switch state {
        case .downloading:
            await task.update(state: .downloading)
            activeTask(withIdentifier: task.identifier)
        case .paused:
            // 外部主动操作，不再同步
//            await task.update(state: .paused)
            inactiveTask(withIdentifier: task.identifier)
        case .stop:
            // 外部主动操作，不再同步
//            await task.update(state: .stop)
            await finishedAct(false)
        case .completed:
            await task.update(state: .completed)
            await finishedAct(true)
        case let .failed(error):
            await task.update(state: .failed(error))
            await finishedAct(false)
            // 处理重试逻辑
            if let retryStrategy = task.taskConfigure.retryStrategy {
                await handleTaskRetry(task: task, error: error, retryStrategy: retryStrategy)
            }
        case .initial:
            break
        }

        let taskState = task.state
        let newState: TaskState
        /// 部份状态需要同步回去
        switch state {
        case .downloading:
            newState = .downloading
            await task.update(state: .downloading)
        case .completed:
            newState = .completed
            await task.update(state: .completed)
        case let .failed(downloadError):
            newState = .failed(downloadError)
            await task.update(state: .failed(downloadError))
        case .paused:
            newState = .paused
        case .initial:
            newState = .pending
        case .stop:
            newState = .stop
        }
        if taskState != newState {
            await notifyStateUpdate() // 通知外部状态已更新
        }
    }

    /// 处理任务重试逻辑
    /// - Parameters:
    ///   - task: 发生错误的任务
    ///   - error: 任务失败的错误
    ///   - retryStrategy: 任务的重试策略
    private func handleTaskRetry(task: DownloadTask, error: DownloadError, retryStrategy: RetryStrategy) async {
        let (interval, shouldRetry) = await retryStrategy.nextRetryInterval(for: task.retryCount, error: error)

        if shouldRetry {
            task.retryCount += 1 // 增加重试次数
            LoggerProxy.ILog(tag: kLogTag, msg: "Retrying task \(task.identifier), attempt: \(task.retryCount). Next retry in \(interval) seconds.")
            // 延迟后重试
            Task { [weak self, weak task] in
                try? await Task.sleep(nanoseconds: UInt64(interval * 1000000000))
                guard let task = task, let self = self else { return }
                await self.startDownloadIfPossible(task) // 尝试重新启动任务
            }
        } else {
            LoggerProxy.WLog(tag: kLogTag, msg: "Max retry attempts reached for task: \(task.identifier). Error: \(error.localizedDescription)")
        }
    }

    /// 处理网络状态变化
    /// - Parameter status: 最新的网络状态
    private func handleNetworkStateChange(_ status: NetworkStatus) async {
        LoggerProxy.ILog(tag: kLogTag, msg: "Network state changed: \(status)")

        switch status {
        case let .connected(type):
            // 网络恢复时，检查配置并尝试恢复暂停的任务
            LoggerProxy.ILog(tag: kLogTag, msg: "Network connected (\(type)). Scheduling paused tasks.")
            await resumePausedTasksBasedOnNetworkType(type)
            await scheduleNextDownloads() // 重新调度所有任务
        case .disconnected:
            LoggerProxy.WLog(tag: kLogTag, msg: "Network disconnected. Pausing all active downloads.")
            // 网络断开时，暂停所有正在下载的任务
            for taskId in allActiveTask() {
                if let task = tasks[taskId], task.state == .downloading {
                    await getDownloader(taskId)?.pause()
                }
            }
        case .restricted:
            LoggerProxy.WLog(tag: kLogTag, msg: "Network restricted.")
            // 可以在此根据配置决定是否暂停蜂窝网络下载
            break
        }
        await notifyStateUpdate() // 通知外部状态已更新
    }

    /// 根据网络类型恢复暂停的任务
    /// - Parameter networkType: 当前的网络类型
    private func resumePausedTasksBasedOnNetworkType(_ networkType: NetworkType) async {
        for taskId in taskOrder {
            if let task = tasks[taskId], task.state == .paused {
                let allowCellular = task.taskConfigure.allowCellularDownloads ?? configuration.defaultTaskConfiguration.allowCellularDownloads ?? true
                let autoResumeOnWifi = configuration.autoResumeOnWifi
                let autoPauseOnCellular = configuration.autoPauseOnCellular

                if networkType == .wifi && autoResumeOnWifi {
                    LoggerProxy.DLog(tag: kLogTag, msg: "Auto-resuming task \(taskId) on WiFi.")
                    await getDownloader(taskId)?.resume()
                } else if networkType == .cellular && allowCellular && !autoPauseOnCellular {
                    LoggerProxy.DLog(tag: kLogTag, msg: "Auto-resuming task \(taskId) on cellular (allowed).")
                    await getDownloader(taskId)?.resume()
                } else if networkType == .cellular && autoPauseOnCellular {
                    LoggerProxy.DLog(tag: kLogTag, msg: "Keeping task \(taskId) paused on cellular due to autoPauseOnCellular setting.")
                    // 任务保持暂停状态
                }
            }
        }
    }

    /// 持久化所有任务的状态
    private func saveTasks() async {
        let downloadTasks = Array(tasks.values)
        try? await persistenceManager.saveTasks(downloadTasks)
        LoggerProxy.DLog(tag: kLogTag, msg: "Saved \(downloadTasks.count) tasks to persistence.")
    }

    /// 通知外部 DownloadManager 更新其状态
    private func notifyStateUpdate() async {
        await saveTasks()
        await stateUpdateHandler?()
    }
}

// MARK: - Public DownloadManager Interface

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
        activeTaskCountPublisher = state.$activeTaskCount.eraseToAnyPublisher()
        allTasksPublisher = state.$allTasks.map({ $0.map({ $0 as DownloadTaskProtocol }) }).eraseToAnyPublisher()
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
            self.startup = true
        }
        LoggerProxy.ILog(tag: kLogTag, msg: "DownloadManager initialized")
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

// MARK: - HTTPChunkDownloadManagerDelegate Extension for DownloadManagerActor

extension DownloadManagerActor: DownloaderDelegate {
    nonisolated func downloader(_ downloader: any Downloader, task: any DownloadTaskProtocol, didUpdateProgress progress: DownloadProgress) async {
        LoggerProxy.VLog(tag: kLogTag, msg: "下载进度:\(task.identifier),progress=\(progress)")
        guard let task = task as? DownloadTask else {
            return
        }
        task.downloadedBytes = progress.downloadedBytes
        task.totalBytes = progress.totalBytes
        await task.update(progress: progress)
    }

    nonisolated func downloader(_ downloader: any Downloader, task: any DownloadTaskProtocol, didUpdateState state: DownloaderState) async {
        LoggerProxy.DLog(tag: kLogTag, msg: "下载状态变化:\(task.identifier),state=\(state)")
        guard let task = task as? DownloadTask else {
            return
        }
        Task {
            await self.handleTaskStateChange(task: task, state: state)
        }
    }

    nonisolated func downloader(_ downloader: any Downloader, didCompleteWith task: any DownloadTaskProtocol) async {
        LoggerProxy.ILog(tag: kLogTag, msg: "下载完成:\(task.identifier)")
        guard let task = task as? DownloadTask else {
            return
        }
    }

    nonisolated func downloader(_ downloader: any Downloader, task: any DownloadTaskProtocol, didFailWithError error: any Error) async {
        LoggerProxy.ILog(tag: kLogTag, msg: "下载失败:\(task.identifier),error=\(error)")
        guard let task = task as? DownloadTask else {
            return
        }
    }
}
