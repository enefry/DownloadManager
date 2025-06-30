//
//  DownloadManagerActor.swift
//  DownloadManager
//
//  Created by chen on 2025/6/30.
//

import Atomics
import Combine
import ConcurrencyCollection
import DownloadManagerBasic
import Foundation
import LoggerProxy
private let kLogTag = "DM.AT"
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
    /// 全局速度 + 时间预计更新
    private var speedUpdateHandler: ((DownloadManagerSpeed) async -> Void)?

    private var globalProgressUpdateHandler: ((DownloadProgress) async -> Void)?

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

    var lastUpdateTime: TimeInterval = 0
    func onSpeedCalculate() async {
        let now = Date().timeIntervalSince1970
        var allTaskTotalBytes: Int64 = 0
        var allTaskDetalBytes: Int64 = 0
        var allTaskDownloadedBytes: Int64 = 0
        for activeTaskId in allActiveTask() {
            if let task = tasks[activeTaskId] {
                if let last = lastDownloadBytes[activeTaskId] {
                    let cost = (now - last.0)
                    if cost <= 0 {
                        // 时间异常
                        continue
                    }

                    let bytes = max(0, task.downloadedBytes - last.1)
                    allTaskDetalBytes += bytes
                    allTaskTotalBytes += max(0, task.totalBytes)
                    allTaskDownloadedBytes += max(0, task.downloadedBytes)
                    LoggerProxy.DLog(tag: kLogTag, msg: "\(activeTaskId)->\(bytes) last:\(last.1) cost:\(cost)")
                    if bytes > 0 {
                        let taskSpeed = Double(bytes) / cost
                        var taskRemining: TimeInterval = -1
                        if task.totalBytes > 0 && taskSpeed > 0 {
                            taskRemining = Double(task.totalBytes - task.downloadedBytes) / taskSpeed
                        }
                        task.update(speed: DownloadManagerSpeed(speed: taskSpeed, remainingTime: taskRemining))
                    } else {
                        task.update(speed: DownloadManagerSpeed(speed: 0, remainingTime: .infinity))
                    }
                }
                lastDownloadBytes[activeTaskId] = (now, task.downloadedBytes)
            }
        }

        if let globalProgressUpdateHandler = globalProgressUpdateHandler {
            await globalProgressUpdateHandler(DownloadProgress(timestamp: now, downloadedBytes: allTaskDownloadedBytes, totalBytes: allTaskTotalBytes))
        }

        if let speedUpdateHandler = speedUpdateHandler {
            if now < 1 {
                lastUpdateTime = now
                return
            }
            let cost = now - lastUpdateTime
            lastUpdateTime = now
            let speed = Double(allTaskDetalBytes) / cost
            var taskRemining: TimeInterval = -1
            if allTaskTotalBytes > 0 && speed > 0 {
                taskRemining = Double(allTaskTotalBytes - allTaskDownloadedBytes) / speed
            }
            await speedUpdateHandler(DownloadManagerSpeed(speed: speed, remainingTime: taskRemining))
        }
    }

    func set(_ downloader: (any Downloader)?, for identifier: String) async {
        if let last = chunkManagers[identifier],
           last !== downloader {
            await last.cancel()
        }
        chunkManagers[identifier] = downloader
    }

    func getDownloader(_ identifier: String) -> (any Downloader)? {
        chunkManagers[identifier]
    }

    /// 设置状态更新处理器
    /// - Parameter handler: 用于更新 DownloadManager 公共状态的闭包
    func setStateUpdateHandler(_ handler: @escaping () async -> Void) {
        stateUpdateHandler = handler
    }

    func setSpeedUpdateHandler(_ handler: @escaping (DownloadManagerSpeed) async -> Void) {
        speedUpdateHandler = handler
    }

    func setProgressUpdateHandler(_ handler: @escaping (DownloadProgress) async -> Void) {
        globalProgressUpdateHandler = handler
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
        inactiveTask(withIdentifier: identifier) // 确保从活跃任务集合中移除
        if let manager = getDownloader(identifier) {
            if cleanupFile {
                await manager.cleanup() // 执行分片管理器的清理操作
            }
            await set(nil, for: identifier)
        }
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

// MARK: - 下载器回调

extension DownloadManagerActor: DownloaderDelegate {
    nonisolated func downloader(_ downloader: any Downloader, task: any DownloadTaskProtocol, didUpdateProgress progress: DownloadProgress) async {
        LoggerProxy.VLog(tag: kLogTag, msg: "下载进度:\(task.identifier),progress=\(progress)")
        guard let task = task as? DownloadTask,
              await hasActiveTask(withIdentifier: task.identifier) else {
            return
        }
        task.downloadedBytes = progress.downloadedBytes
        task.totalBytes = progress.totalBytes
        await task.update(progress: progress)
    }

    nonisolated func downloader(_ downloader: any Downloader, task: any DownloadTaskProtocol, didUpdateState state: DownloaderState) async {
        LoggerProxy.DLog(tag: kLogTag, msg: "下载状态变化:\(task.identifier),state=\(state)")
        guard let task = task as? DownloadTask,
              await hasActiveTask(withIdentifier: task.identifier) else {
            return
        }
        Task {
            await self.handleTaskStateChange(task: task, state: state)
        }
    }

    nonisolated func downloader(_ downloader: any Downloader, didCompleteWith task: any DownloadTaskProtocol) async {
        LoggerProxy.ILog(tag: kLogTag, msg: "下载完成:\(task.identifier)")
        guard let task = task as? DownloadTask,
              await hasActiveTask(withIdentifier: task.identifier) else {
            return
        }
    }

    nonisolated func downloader(_ downloader: any Downloader, task: any DownloadTaskProtocol, didFailWithError error: any Error) async {
        LoggerProxy.ILog(tag: kLogTag, msg: "下载失败:\(task.identifier),error=\(error)")
        guard let task = task as? DownloadTask,
              await hasActiveTask(withIdentifier: task.identifier) else {
            return
        }
    }
}

// MARK: - 外部操作

/// 操作判断
extension DownloadManagerActor {
    // MARK: - 停止

    private func canPause(_ state: TaskState) -> Bool {
        return state.allowOperations().contains(.pause)
    }

    private func canRemove(_ state: TaskState) -> Bool {
        return state.allowOperations().contains(.remove)
    }

    private func canStop(_ state: TaskState) -> Bool {
        return state.allowOperations().contains(.stop)
    }

    private func canPause(_ task: DownloadTask) -> Bool {
        canPause(task.state)
    }

    private func canRemove(_ task: DownloadTask) -> Bool {
        canRemove(task.state)
    }

    private func canStop(_ task: DownloadTask) -> Bool {
        canStop(task.state)
    }

    // MARK: - 恢复

    private func canResume(_ state: TaskState) -> Bool {
        return state.allowOperations().contains(.resume)
    }

    private func canRestart(_ state: TaskState) -> Bool {
        return state.allowOperations().contains(.restart)
    }

    private func canResume(_ task: DownloadTask) -> Bool {
        canResume(task.state)
    }

    private func canRestart(_ task: DownloadTask) -> Bool {
        canRestart(task.state)
    }
}

/// 实际操作
extension DownloadManagerActor {
    // MARK: - 停止

    @discardableResult
    private func __disable(task: DownloadTask, state: TaskState) async -> Downloader? {
        inactiveTask(withIdentifier: task.identifier)
        await task.update(state: state)
        let downloader = getDownloader(task.identifier)
        /// 取消下载器
        await set(nil, for: task.identifier)
        return downloader
    }

    private func __pause(task: DownloadTask) async -> Bool {
        if !canPause(task) {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task can not pause:\(task.identifier):\(task.state)")
            return false
        }
        LoggerProxy.ILog(tag: kLogTag, msg: "pausing task: \(task.identifier)")
        await __disable(task: task, state: .paused)
        return true
    }

    private func __stop(task: DownloadTask, cleanupFile: Bool) async -> Bool {
        if !canStop(task) {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task can not stop:\(task.identifier):\(task.state)")
            return false
        }
        LoggerProxy.ILog(tag: kLogTag, msg: "stop task: \(task.identifier)")
        if let downloader = await __disable(task: task, state: .stop),
           cleanupFile {
            await downloader.cleanup() // 执行分片管理器的清理操作
        }
        return true
    }

    private func __remove(task: DownloadTask, cleanupFile: Bool) async -> Bool {
        if !canRemove(task) {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task can not remove:\(task.identifier):\(task.state)")
            return false
        }

        LoggerProxy.DLog(tag: kLogTag, msg: "removed task: \(task.identifier)")

        if let downloader = await __disable(task: task, state: .stop),
           cleanupFile {
            await downloader.cleanup() // 执行分片管理器的清理操作
        }
        tasks.removeValue(forKey: task.identifier)
        taskOrder.removeAll { $0 == task.identifier }
        await saveTasks()
        return true
    }

    // MARK: - 恢复

    private func __resume(task: DownloadTask) async -> Bool {
        // 是否可以恢复
        if !canResume(task) {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task can not resume:\(task.identifier):\(task.state)")
            return false
        }
        LoggerProxy.ILog(tag: kLogTag, msg: "resume task: \(task.identifier)")
        await task.update(state: .pending) // 重新排队
        return true
    }

    private func __restart(task: DownloadTask) async -> Bool {
        if !canRestart(task) {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task can not restart:\(task.identifier):\(task.state)")
            return false
        }
        LoggerProxy.ILog(tag: kLogTag, msg: "restart task:\(task.identifier)")
        await task.update(state: .pending) // 重新排队
        return true
    }
}

extension DownloadManagerActor {
    /// 暂停指定标识符的任务
    /// - Parameter identifier: 任务的唯一标识符
    func pauseTask(withIdentifier identifier: String) async {
        guard let task = tasks[identifier] else {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task not found for pause: \(identifier)")
            return
        }

        if await __pause(task: task) {
            await scheduleNextDownloads() // 暂停后重新调度其他任务
            await scheduleNextDownloads() // 取消后重新调度
        }
    }

    /// 恢复指定标识符的任务
    /// - Parameter identifier: 任务的唯一标识符
    func resumeTask(withIdentifier identifier: String) async {
        guard let task = tasks[identifier] else {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task not found for resume: \(identifier)")
            return
        }

        if await __resume(task: task) {
            await notifyStateUpdate() // 通知外部状态已更新
            await scheduleNextDownloads() // 取消后重新调度
        }
    }

    /// 取消指定标识符的任务
    /// - Parameter identifier: 任务的唯一标识符
    func stopTask(withIdentifier identifier: String, cleanupFile: Bool) async {
        guard let task = tasks[identifier] else {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task not found for cancel: \(identifier)")
            return
        }

        if await __stop(task: task, cleanupFile: cleanupFile) { // 清理分片管理器
            await notifyStateUpdate() // 通知外部状态已更新
            await scheduleNextDownloads() // 取消后重新调度
        }
    }

    /// 移除指定标识符的任务
    /// - Parameter identifier: 任务的唯一标识符
    /// - Parameter cleanup: 是否同时清理下载的临时文件
    func removeTask(withIdentifier identifier: String, cleanupFile: Bool) async {
        guard let task = tasks[identifier] else {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task not found for remove: \(identifier)")
            return
        }

        if await __remove(task: task, cleanupFile: cleanupFile) {
            await notifyStateUpdate() // 通知外部状态已更新
            await scheduleNextDownloads() // 取消后重新调度
        }
    }

    func restart(withIdentifier identifier: String) async {
        guard let task = tasks[identifier] else {
            LoggerProxy.WLog(tag: kLogTag, msg: "Task not found for remove: \(identifier)")
            return
        }

        if await __restart(task: task) {
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

        // 尝试启动这个高优先级任务
        await startDownloadIfPossible(task)
        await saveTasks() // 保存任务顺序变化
        await notifyStateUpdate() // 通知外部状态已更新
    }

    // MARK: - Batch Operations

    private func __batch(op: (DownloadTask) async -> Bool, functionName: StaticString = #function, line: Int = #line) async {
        LoggerProxy.ILog(tag: kLogTag, msg: "all tasks op", funcName: functionName, line: line)
        var activeCount: Int = 0
        for task in tasks.values {
            if await op(task) {
                activeCount += 1
            }
        }
        LoggerProxy.ILog(tag: kLogTag, msg: "all tasks op for\(activeCount)", funcName: functionName, line: line)
        if activeCount > 0 {
            await notifyStateUpdate() // 通知外部状态已更新
            await scheduleNextDownloads() // 暂停所有后，确保队列空闲
        }
    }

    /// 暂停所有下载任务
    func pauseAllTasks() async {
        await __batch(op: __pause)
    }

    /// 恢复所有可恢复的下载任务
    func resumeAllTasks() async {
        await __batch(op: __resume)
    }

    private func __cleanupRecords() async {
        tasks.removeAll()
        taskOrder.removeAll()
        removeAllActiveTasks()
        try? await persistenceManager.clearTasks() // 清除持久化数据
        await notifyStateUpdate() // 通知外部状态已更新
    }

    /// 取消所有下载任务
    func stopAllTasks() async throws {
        await __batch(op: { await __remove(task: $0, cleanupFile: false) })
        await __cleanupRecords()
    }

    /// 移除所有已完成（成功或失败）的任务
    func removeAllFinishedTasks() async {
        LoggerProxy.ILog(tag: kLogTag, msg: "Removing all finished tasks")
        await __batch {
            if !$0.state.isFinished {
                return false
            }
            return await __remove(task: $0, cleanupFile: true)
        }
    }

    /// 移除所有任务
    func removeAllTasks() async {
        LoggerProxy.ILog(tag: kLogTag, msg: "Removing all tasks")
        await __batch(op: { await __remove(task: $0, cleanupFile: true) })
        await __cleanupRecords()
    }
}
