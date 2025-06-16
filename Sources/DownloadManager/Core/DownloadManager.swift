import Atomics
import Combine
import ConcurrencyCollection
import Foundation

public final class DownloadManager: DownloadManagerProtocol {
    // MARK: - 公开属性

    internal var _activeTaskCountSubject = CurrentValueSubject<Int, Never>(0)
    public lazy var activeTaskCountPublisher: AnyPublisher<Int, Never> = _activeTaskCountSubject.eraseToAnyPublisher()

    // 这个是一个线程安全容器，接口和 array对齐
    public var tasks: ConcurrencyCollection.ConcurrentArray<any DownloadTaskProtocol> = ConcurrentArray()

    public var _activeTaskCount = ManagedAtomic<Int>(0)
    public var activeTaskCount: Int {
        _activeTaskCount.load(ordering: .relaxed)
    }

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

    public var maxConcurrentDownloads: Int {
        get {
            configuration.maxConcurrentDownloads
        }
        set {
            queue.async { [weak self] in
                guard let self = self else {
                    return
                }
                self.configuration.maxConcurrentDownloads = newValue
                self.checkAndScheduleDownload()
            }
        }
    }

    // MARK: - 私有属性

    private var persistenceManager: DownloadPersistenceManager
    private var configuration: DownloadManagerConfiguration
    private let session: URLSession
    private let queue = DispatchQueue(label: "com.downloadmanager", qos: .utility)
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化

    public init(configuration: DownloadManagerConfiguration) {
        self.configuration = configuration
        persistenceManager = DownloadPersistenceManager()

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 300
        session = URLSession(configuration: sessionConfig)

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
            configuration: taskConfig,
            session: session
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
                taskConfigure: task.taskConfigure
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

//    private func scheduleNextDownload() {
//        queue.async { [weak self] in
//            guard let self = self else { return }
//
//            // 查找等待中的任务
//            if let waitingTask = self.tasks.values.first(where: { task in
//                if let downloadTask = task as? DownloadTask {
//                    return downloadTask.state == .waiting
//                }
//                return false
//            }) as? DownloadTask {
//                self.startDownload(waitingTask)
//            }
//        }
//    }

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
