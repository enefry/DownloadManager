import Atomics
import Combine
import ConcurrencyCollection
import Foundation

public final class DownloadManager: DownloadManagerProtocol {
    // MARK: - 公开属性

    public lazy var activeTaskCountPublisher: AnyPublisher<Int, Never> = _activeTaskCountSubject.eraseToAnyPublisher()

    public var allTasks: [any DownloadTaskProtocol] { tasks.values }

    public var activeTaskCount: Int { _activeTaskCount.load(ordering: .relaxed) }

    public var maxConcurrentDownloads: Int {
        get {
            configuration.maxConcurrentDownloads
        }
        set {
            configuration.maxConcurrentDownloads = newValue
            checkAndScheduleDownload()
        }
    }

    public func pause(task: any DownloadTaskProtocol) {
        pause(withIdentifier: task.identifier)
    }

    public func pause(withIdentifier identifier: String) {
        queue.async { [weak self] in
            guard let self = self,
                  let task = self.task(withIdentifier: identifier) as? DownloadTask else {
                return
            }
            // 暂停后，会出发状态更新，状态更新后，会出发队列新下载
            task.pause()
            // 检查是否可以开始新的下载
            self.checkAndScheduleDownload()
        }
    }

    public func resume(task: any DownloadTaskProtocol) {
        resume(withIdentifier: task.identifier)
    }

    public func resume(withIdentifier identifier: String) {
        queue.async { [weak self] in
            guard let self = self,
                  let task = self.task(withIdentifier: identifier) as? DownloadTask else {
                return
            }
            // 恢复下载，将任务状态设置为等待中，然后检查是否可以开始下载
            task.resume()
            self.checkAndScheduleDownload()
        }
    }

    public func cancel(task: any DownloadTaskProtocol) {
        cancel(withIdentifier: task.identifier)
    }

    public func cancel(withIdentifier identifier: String) {
        queue.async { [weak self] in
            guard let self = self,
                  let task = self.task(withIdentifier: identifier) as? DownloadTask else {
                return
            }
            // 取消下载任务
            task.cancel()
            // 检查是否可以开始新的下载
            self.checkAndScheduleDownload()
        }
    }

    public func remove(task: any DownloadTaskProtocol) {
        remove(withIdentifier: task.identifier)
    }

    public func remove(withIdentifier identifier: String) {
        queue.async { [weak self] in
            guard let self = self,
                  let task = self.task(withIdentifier: identifier) as? DownloadTask else {
                return
            }
            // 如果任务正在下载，先取消
            if task.state == .downloading {
                task.cancel()
            }
            // 从任务列表中移除
            self.removeTask(withIdentifier: identifier)
            // 检查是否可以开始新的下载
            self.checkAndScheduleDownload()
        }
    }

    public func insert(task: any DownloadTaskProtocol) {
        insert(withIdentifier: task.identifier)
    }

    public func insert(withIdentifier identifier: String) {
        queue.async { [weak self] in
            guard let self = self,
                  let task = self.task(withIdentifier: identifier) as? DownloadTask else {
                return
            }
            // 将新任务添加到队列开头
            self.tasks.safeWrite { queue in
                queue.removeAll(where: { $0.identifier == task.identifier })
                queue.insert(task, at: 0)
            }

            // 如果任务数量超过最大并发数，需要暂停最后一个任务
            if self.activeTaskCount >= self.maxConcurrentDownloads {
                // 找到最后一个正在下载的任务并暂停
                for task in self.tasks.values.reversed() {
                    if let downloadTask = task as? DownloadTask,
                       downloadTask.state == .downloading {
                        downloadTask.pause()
                        break
                    }
                }
            }
            // 开始新任务的下载
            self.startDownload(task)
            // 持久化保存
            self.persistenceManager.saveTasks(self.tasks.values.compactMap { $0 as? DownloadTask })
        }
    }

    // MARK: - 私有属性

    // 这个是一个线程安全容器，接口和 array对齐
    private var tasks: ConcurrencyCollection.ConcurrentArray<any DownloadTaskProtocol> = ConcurrentArray()

    /// 当前有效任务数
    private var _activeTaskCount = ManagedAtomic<Int>(0)
    /// 事件发送
    private var _activeTaskCountSubject = CurrentValueSubject<Int, Never>(0)
    private func increaseActive() {
        let newValue = _activeTaskCount.wrappingIncrementThenLoad(
            ordering: .releasing
        )
        _activeTaskCountSubject.send(newValue)
    }

    private func decreaseActive() {
        let newValue = _activeTaskCount.wrappingDecrementThenLoad(
            ordering: .releasing
        )
        _activeTaskCountSubject.send(newValue)
    }

    /// 队列持久化管理器
    private var persistenceManager: DownloadPersistenceManager
    /// 管理器配置
    private var configuration: DownloadManagerConfiguration
    /// 下载队列
    private let queue = DispatchQueue(label: "com.downloadmanager", qos: .utility)
    private var sessionConfig: URLSessionConfiguration
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化

    public init(configuration: DownloadManagerConfiguration) {
        self.configuration = configuration
        persistenceManager = DownloadPersistenceManager()

        sessionConfig = URLSessionConfiguration.default
        sessionConfig.allowsCellularAccess = configuration.allowCellularDownloads
        sessionConfig.allowsExpensiveNetworkAccess = !configuration.autoPauseOnCellular
        sessionConfig.connectionProxyDictionary = configuration.connectionProxyDictionary
        if let timeoutIntervalForResource = configuration.timeoutIntervalForResource {
            sessionConfig.timeoutIntervalForResource = timeoutIntervalForResource
        }
        if let timeoutIntervalForRequest = configuration.timeoutIntervalForRequest {
            sessionConfig.timeoutIntervalForRequest = timeoutIntervalForRequest
        }

        // 从持久化存储加载任务
        loadPersistedTasks()

        // 监听网络状态变化
        setupNetworkMonitoring()
    }

    // MARK: - 私有方法

    private func loadPersistedTasks() {
        let persistedTasks = persistenceManager.loadTasks()
        for task in persistedTasks {
            tasks.append(task)
        }
    }

    private func setupNetworkMonitoring() {
        NetworkMonitor.shared.statusPublisher.sink { [weak self] state in
            self?.updateNetworkState(state: state)
        }.store(in: &cancellables)
    }

    private func updateNetworkState(state: NetworkStatus) {
        print("更新网络状态")
        // TODO: 网络状态变化，任务变化
    }

    public func download(url: URL, destination: URL, configuration: DownloadTaskConfiguration?) -> any DownloadTaskProtocol {
        let identifier = DownloadTask.buildIdentifier(
            url: url,
            destinationURL: destination
        )
        // 检查是否已存在相同identifier的任务
        if let existingTask = task(withIdentifier: identifier) {
            return existingTask
        }

        // 创建新的下载任务
        let taskConfig = configuration ?? self.configuration.defaultTaskConfiguration
        let task = DownloadTask(
            url: url,
            destinationURL: destination,
            identifier: identifier,
            configuration: taskConfig
        )

        // 保存任务到队列
        tasks.append(task)

        // 持久化保存
        let currentTasks = tasks.values
        persistenceManager.saveTasks(currentTasks.compactMap { $0 as? DownloadTask })

        // 开始下载
        startDownload(task)

        return task
    }

    private func startDownload(_ task: DownloadTask) {
        queue.async { [weak self] in
            guard let self = self else { return }

            // 检查并发数限制
            if self.activeTaskCount >= self.maxConcurrentDownloads {
                return
            }

            // 创建分片下载管理器
            let chunkConfig = ChunkConfiguration(
                chunkSize: task.taskConfigure.chunkSize,
                maxConcurrentChunks: task.taskConfigure.maxConcurrentChunks,
                timeoutInterval: task.taskConfigure.timeoutInterval,
                taskConfigure: task.taskConfigure,
                sessionConfigure: self.sessionConfig
            )

            let chunkManager = ChunkDownloadManager(
                downloadTask: task,
                configuration: chunkConfig,
                delegate: self
            )

            // 开始下载
            chunkManager.start()

            // 更新活动任务数
            self.increaseActive()
        }
    }

    public func pauseAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            for task in self.tasks.values {
                if let downloadTask = task as? DownloadTask {
                    downloadTask.pause()
                }
            }
        }
    }

    public func resumeAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            for task in self.tasks.values {
                if let downloadTask = task as? DownloadTask {
                    downloadTask.resume()
                }
            }
        }
    }

    public func cancelAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            for task in self.tasks.values {
                if let downloadTask = task as? DownloadTask {
                    downloadTask.cancel()
                }
            }
            self.tasks.removeAll()
            self.persistenceManager.clearTasks()
        }
    }

    public func removeAllFinish() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let unfinishedTasks = self.tasks.values.filter { task in
                if let downloadTask = task as? DownloadTask {
                    return downloadTask.state != .completed
                }
                return true
            }
            self.tasks = ConcurrentArray(unfinishedTasks)
            self.persistenceManager.saveTasks(unfinishedTasks.compactMap { $0 as? DownloadTask })
        }
    }

    public func removeAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.tasks.removeAll()
            self.persistenceManager.clearTasks()
        }
    }

    public func task(withIdentifier identifier: String) -> (any DownloadTaskProtocol)? {
        return tasks.values.first { $0.identifier == identifier }
    }

    public func task(withURL url: URL) -> (any DownloadTaskProtocol)? {
        return tasks.values.first { $0.url == url }
    }

    public func removeTask(withIdentifier identifier: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let index = self.tasks.values.firstIndex(where: { $0.identifier == identifier }) {
                self.tasks.remove(at: index)
                self.persistenceManager.saveTasks(self.tasks.values.compactMap { $0 as? DownloadTask })
            }
        }
    }

    public func removeTask(withURL url: URL) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let index = self.tasks.values.firstIndex(where: { $0.url == url }) {
                self.tasks.remove(at: index)
                self.persistenceManager.saveTasks(self.tasks.values.compactMap { $0 as? DownloadTask })
            }
        }
    }

    public func waitForAllTasks() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: DownloadError.unknown("DownloadManager已释放"))
                    return
                }

                let group = DispatchGroup()
                var lastError: Error?

                for task in self.tasks.values {
                    group.enter()
                    if let downloadTask = task as? DownloadTask {
                        downloadTask.statePublisher
                            .filter { $0.isFinished }
                            .prefix(1)
                            .sink { state in
                                if case let .failed(error) = state {
                                    lastError = error
                                }
                                group.leave()
                            }
                            .store(in: &self.cancellables)
                    } else {
                        group.leave()
                    }
                }

                group.notify(queue: .main) {
                    if let error = lastError {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
}

// MARK: - ChunkDownloadManagerDelegate

extension DownloadManager: ChunkDownloadManagerDelegate {
    public func chunkDownloadManager(_ manager: ChunkDownloadManager, didUpdateProgress progress: Double) {
        // 进度更新由 DownloadTask 内部处理
        if let task = manager.downloadTask as? DownloadTask {
            task.progressSubject.send(progress)
        }
    }

    public func chunkDownloadManager(_ manager: ChunkDownloadManager, didUpdateState state: DownloadState) {
        if let task = manager.downloadTask as? DownloadTask {
            task.stateSubject.send(state)
        }

        if state.isFinished {
            // 如果是任务完成，刷新活动任务数，并开始新任务
            decreaseActive()
            checkAndScheduleDownload()
        }
    }

    public func chunkDownloadManager(_ manager: ChunkDownloadManager, didCompleteWithURL url: URL) {
        // 下载完成由 DownloadTask 内部处理
    }

    public func chunkDownloadManager(_ manager: ChunkDownloadManager, didFailWithError error: Error) {
        queue.async { [weak self] in
            guard let self = self else { return }

            // 检查是否需要重试
            if let downloadTask = manager.downloadTask as? DownloadTask,
               let retryStrategy = downloadTask.taskConfigure.retryStrategy {
                let downloadError = error as? DownloadError ?? DownloadError.unknown(error.localizedDescription)
                let shouldRetry = retryStrategy.shouldRetry(error: downloadError, attempt: downloadTask.retryCount)

                if shouldRetry {
                    // 重新调度下载
                    self.startDownload(downloadTask)
                }
            }
        }
    }

    // 检查下载并发数量，暂停或者开始新的下载任务
    private func checkAndScheduleDownload() {
        queue.async { [weak self] in
            guard let self = self else { return }

            // 获取当前活动任务数
            let currentActiveCount = self.activeTaskCount

            // 如果当前活动任务数超过最大并发数，需要暂停一些任务
            if currentActiveCount > self.maxConcurrentDownloads {
                // 计算需要暂停的任务数量
                let tasksToPause = currentActiveCount - self.maxConcurrentDownloads

                // 找到正在下载的任务并暂停
                var pausedCount = 0
                for task in self.tasks.values {
                    if pausedCount >= tasksToPause {
                        break
                    }

                    if let downloadTask = task as? DownloadTask,
                       downloadTask.state == .downloading {
                        downloadTask.pause()
                        pausedCount += 1
                    }
                }
            }
            // 如果当前活动任务数小于最大并发数，可以启动新的下载任务
            else if currentActiveCount < self.maxConcurrentDownloads {
                // 计算可以启动的新任务数量
                let availableSlots = self.maxConcurrentDownloads - currentActiveCount

                // 找到等待中的任务并启动
                var startedCount = 0
                for task in self.tasks.values {
                    if startedCount >= availableSlots {
                        break
                    }

                    if let downloadTask = task as? DownloadTask,
                       downloadTask.state == .waiting {
                        self.startDownload(downloadTask)
                        startedCount += 1
                    }
                }
            }
        }
    }
}
