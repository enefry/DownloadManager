import Combine
import ConcurrencyCollection
import CryptoKit
import Darwin.C // 引入 C 标准库，包含 open/read/write/close 等函数
import DownloadManagerBasic
import Foundation
import LoggerProxy

fileprivate let kLogTag = "DM.HD"

/// 合并后的下载管理器 Actor
public actor HTTPDownloadManager: HTTPChunkDownloadManagerProtocol { /// nonisolated
    /// 任务信息
    private struct TaskInfo: Codable, Sendable, Equatable, Hashable {
        var src: String
        var dest: String
        var identifier: String
        var chunkAvailable: Bool?
        var totalBytes: Int64 = 0
    }

    /// 分块任务 - 基于 DataTask 的可控下载方案
    private class Chunk: NSObject, Sendable, URLSessionDataDelegate {
        let identifier: String
        let index: Int
        let downloadTask: any HTTPChunkDownloadTaskProtocol
        let start: Int64
        let end: Int64
        var downloadedBytes: Int64
        var filePath: URL
        var isCompleted: Bool
        var task: URLSessionDataTask?
        var bytesWritten: Int64 = 0

        // 文件句柄用于写入数据
        private var fileHandle: FileHandle?
        private var fileOutputStream: OutputStream?

        // 用于异步等待下载完成
        private var completionLock = NSLock()
        private var __downloadCompletion: CheckedContinuation<URL, Error>?

        // 进度回调
        var onProgressUpdate: ((Chunk, Int64, Int64) -> Void)?

        // 下载状态
        private var isPaused = false
        private var isCancelled = false

        // 数据缓冲区
        private var dataBuffer = Data()
        private let bufferSize = 64 * 1024 // 64KB 缓冲区

        var totalChunkSize: Int64 {
            end - start + 1
        }

        init(identifier: String, index: Int, downloadTask: any HTTPChunkDownloadTaskProtocol, start: Int64, end: Int64, downloadedBytes: Int64, filePath: URL, isCompleted: Bool, task: URLSessionDataTask? = nil) {
            self.identifier = identifier
            self.index = index
            self.downloadTask = downloadTask
            self.start = start
            self.end = end
            self.downloadedBytes = downloadedBytes
            self.filePath = filePath
            self.isCompleted = isCompleted
            self.task = task
            super.init()
        }

        deinit {
            closeFileHandle()
        }

        // MARK: - 文件操作

        private func prepareFileForWriting() throws {
            let targetDirectory = filePath.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: targetDirectory.path) {
                try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            }

            // 如果文件不存在，创建空文件
            if !FileManager.default.fileExists(atPath: filePath.path) {
                FileManager.default.createFile(atPath: filePath.path, contents: nil)
            }

            // 打开文件用于写入
            let fileHandle = try FileHandle(forWritingTo: filePath)
            if downloadedBytes > 0 { // 如果外面传入需要续传，才续
                let fileEnd = Int64(try fileHandle.seekToEnd())
                if fileEnd > downloadedBytes {
                    try fileHandle.seek(toOffset: UInt64(downloadedBytes))
                } else if fileEnd < downloadedBytes {
                    throw DownloadError.fileIOError("Invalid File Length:\(fileEnd) request is \(downloadedBytes) for \(identifier)")
                }
            }

            self.fileHandle = fileHandle
        }

        private func writeDataToFile(_ data: Data) throws {
            guard let fileHandle = fileHandle else {
                throw DownloadError.fileIOError("File handle not available for \(identifier)")
            }

            try fileHandle.write(contentsOf: data)
            bytesWritten += Int64(data.count)
            downloadedBytes += Int64(data.count)
        }

        private func closeFileHandle() {
            try? fileHandle?.close()
            fileHandle = nil
        }

        // MARK: - URLSessionDataDelegate

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
            LoggerProxy.DLog(tag: kLogTag, msg: "Chunk \(identifier) received response: \(response)")

            // 验证响应状态码
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 206 || httpResponse.statusCode == 200 {
                    do {
                        try prepareFileForWriting()
                    } catch {
                        LoggerProxy.DLog(tag: kLogTag, msg: "Chunk \(identifier) failed to prepare file: \(error)")
                        sendCompletion(.failure(error))
                        return .cancel
                    }
                } else {
                    LoggerProxy.DLog(tag: kLogTag, msg: "Chunk \(identifier) unexpected status code: \(httpResponse.statusCode)")
                    sendCompletion(.failure(DownloadError.networkError("响应码：\(httpResponse.statusCode)")))
                    return .cancel
                }
            } else {
                sendCompletion(.failure(DownloadError.invalidResponse))
                return .cancel
            }

            return .allow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !isCancelled && !isPaused else { return }

            LoggerProxy.VLog(tag: kLogTag, msg: "Chunk \(identifier) received \(data.count) bytes")

            // 将数据添加到缓冲区
            dataBuffer.append(data)

            // 当缓冲区达到一定大小时，写入文件
            if dataBuffer.count >= bufferSize {
                do {
                    try writeDataToFile(dataBuffer)
                    dataBuffer.removeAll(keepingCapacity: true)

                    // 更新进度
                    onProgressUpdate?(self, downloadedBytes, totalChunkSize)
                    LoggerProxy.VLog(tag: kLogTag, msg: "Chunk \(identifier) progress: \(downloadedBytes)/\(totalChunkSize)")
                } catch {
                    LoggerProxy.DLog(tag: kLogTag, msg: "Chunk \(identifier) write error: \(error)")
                    sendCompletion(.failure(error))
                    task?.cancel()
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            defer {
                closeFileHandle()
            }

            if let error = error {
                if (error as NSError).code == NSURLErrorCancelled {
                    LoggerProxy.DLog(tag: kLogTag, msg: "Chunk \(identifier) download cancelled")
                } else {
                    LoggerProxy.DLog(tag: kLogTag, msg: "Chunk \(identifier) download error: \(error)")
                }
                sendCompletion(.failure(error))
                return
            }

            // 写入剩余缓冲区数据
            if !dataBuffer.isEmpty {
                do {
                    try writeDataToFile(dataBuffer)
                    dataBuffer.removeAll()
                } catch {
                    LoggerProxy.DLog(tag: kLogTag, msg: "Chunk \(identifier) final write error: \(error)")
                    sendCompletion(.failure(error))
                    return
                }
            }

            // 验证下载完整性
            let expectedSize = totalChunkSize
            if downloadedBytes >= expectedSize {
                isCompleted = true
                LoggerProxy.DLog(tag: kLogTag, msg: "Chunk \(identifier) download completed successfully")
                sendCompletion(.success(filePath))
            } else {
                let error = DownloadError.corruptedChunk("Chunk \(identifier) incomplete download: \(downloadedBytes)/\(expectedSize) for :\(identifier)")
                LoggerProxy.DLog(tag: kLogTag, msg: "Chunk \(identifier) incomplete download: \(downloadedBytes)/\(expectedSize)")
                sendCompletion(.failure(error))
            }
        }

        private func set(completionContinuation: CheckedContinuation<URL, Error>?) {
            completionLock.lock()
            defer {
                self.completionLock.unlock()
            }
            __downloadCompletion = completionContinuation
        }

        private func sendCompletion(_ result: Result<URL, any Error>) {
            completionLock.lock()
            defer {
                self.completionLock.unlock()
            }
            if let downloadCompletion = __downloadCompletion {
                downloadCompletion.resume(with: result)
            }
            __downloadCompletion = nil
        }

        // MARK: - 下载控制方法

        /// 开始下载分块
        func startDownload(with session: URLSession, request: URLRequest) async throws -> URL {
            isCancelled = false
            isPaused = false
            return try await withTaskCancellationHandler {
                return try await withCheckedThrowingContinuation { continuation in
                    self.set(completionContinuation: continuation)
                    LoggerProxy.DLog(tag: kLogTag, msg: "Chunk \(identifier) starting download with range: \(request)")
                    // 创建数据任务
                    let dataTask = session.dataTask(with: request)
                    self.task = dataTask
                    dataTask.delegate = self

                    // 开始下载
                    dataTask.resume()
                    if Task.isCancelled {
                        dataTask.cancel()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                self.cancelDownload()
            }
        }

        /// 暂停下载
        func pauseDownload() {
            isPaused = true
            task?.suspend()
            LoggerProxy.DLog(tag: kLogTag, msg: "Chunk \(identifier) paused at \(downloadedBytes) bytes")
        }

        /// 恢复下载
        func resumeDownload() {
            isPaused = false
            task?.resume()
            LoggerProxy.DLog(tag: kLogTag, msg: "Chunk \(identifier) resumed from \(downloadedBytes) bytes")
        }

        /// 取消下载
        func cancelDownload() {
            isCancelled = true
            task?.cancel()
            closeFileHandle()
            sendCompletion(.failure(CancellationError()))
            LoggerProxy.DLog(tag: kLogTag, msg: "Chunk \(identifier) cancelled")
        }

        /// 重置分块（清除已下载数据，重新开始）
        func resetChunk() throws {
            cancelDownload()
            downloadedBytes = 0
            bytesWritten = 0
            isCompleted = false

            // 删除已下载的文件
            if FileManager.default.fileExists(atPath: filePath.path) {
                try FileManager.default.removeItem(at: filePath)
            }

            LoggerProxy.DLog(tag: kLogTag, msg: "Chunk \(identifier) reset")
        }

        /// 获取当前下载进度
        func getProgress() -> Double {
            guard totalChunkSize > 0 else { return 0.0 }
            return Double(downloadedBytes) / Double(totalChunkSize)
        }

        /// 获取下载速度 (需要外部调用者计算)
        func getCurrentDownloadedBytes() -> Int64 {
            return downloadedBytes
        }
    }

//    /// 分块任务
//    private class Chunk: NSObject, Sendable, URLSessionDownloadDelegate {
//        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
//            finishLocation = location
//        }
//
//        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
//            progress = DownloadProgress(downloadedBytes: bytesWritten, totalBytes: totalBytesWritten)
//        }
//
//        let identifier: String
//        let index: Int
//        let downloadTask: any HTTPChunkDownloadTaskProtocol
//        let start: Int64
//        let end: Int64
//        var downloadedBytes: Int64
//        var filePath: URL
//        var isCompleted: Bool
//        var task: URLSessionDownloadTask?
//        var bytesWritten: Int64 = 0
//        @Published var finishLocation: URL?
//        @Published var progress: DownloadProgress = DownloadProgress(downloadedBytes: 0, totalBytes: 0)
//
//        var totalChunkSize: Int64 {
//            end - start + 1
//        }
//
//        init(identifier: String, index: Int, downloadTask: any HTTPChunkDownloadTaskProtocol, start: Int64, end: Int64, downloadedBytes: Int64, filePath: URL, isCompleted: Bool, task: URLSessionDownloadTask? = nil) {
//            self.identifier = identifier
//            self.index = index
//            self.downloadTask = downloadTask
//            self.start = start
//            self.end = end
//            self.downloadedBytes = downloadedBytes
//            self.filePath = filePath
//            self.isCompleted = isCompleted
//            self.task = task
//        }
//    }

    /// 当前下载任务的信息，用于记录内部状态
    private var taskInfoSavePath: URL
    private var taskInfo: TaskInfo
    /// 下载任务
    private let downloadTask: any HTTPChunkDownloadTaskProtocol
    /// 分块配置
    private let configuration: HTTPChunkDownloadConfiguration
    /// 下载session
    private var session: URLSession
    /// 并发任务存储
    private let activeTasks = ConcurrentDictionary<String, Task<Void, Never>>()
    /// 分块任务
    private var chunkTasks: [Chunk] = []
    /// 正在下载的分块
    private var activeTaskIndices: Set<String> = []
    /// 下载的临时目录，完成后会删除
    private var tempDirectory: URL
    /// 完整大小
    private var totalBytes: Int64 = -1
    /// 已经下载的大小
    private var taskDownloadedBytes: [String: Int64] = [:]
    /// 上一次进度更新时间
    private var lastProgressUpdate: Date = .distantPast
    /// 当前下载器状态，不直接关联task，避免被多个task关联
    @Published public var state: ChunkDownloadState = .initialed
    /// 检查过可以分块
    public var chunkAvailable: Bool = false

    /// 更新进度
    private func update(progress: DownloadProgress) async {
        await delegate?.HTTPChunkDownloadManager(self, task: downloadTask, didUpdateProgress: progress)
    }

    /// 更新状态
    private func update(state: ChunkDownloadState) async {
        LoggerProxy.DLog(tag: kLogTag, msg: "update(state:\(state))")
        self.state = state
        await delegate?.HTTPChunkDownloadManager(self, task: downloadTask, didUpdateState: state)
        if case .completed = state {
            await delegate?.HTTPChunkDownloadManager(self, didCompleteWith: downloadTask)
        } else if case let .failed(downloadError) = state {
            await delegate?.HTTPChunkDownloadManager(self, task: downloadTask, didFailWithError: downloadError)
        }
    }

    private weak var delegate: HTTPChunkDownloadManagerDelegate?
    var cancellable: [AnyCancellable] = []

    // MARK: - 初始化

    public init(downloadTask: any HTTPChunkDownloadTaskProtocol, configuration: HTTPChunkDownloadConfiguration, delegate: HTTPChunkDownloadManagerDelegate) {
        self.downloadTask = downloadTask
        self.configuration = configuration
        self.delegate = delegate
        session = URLSession(
            configuration: downloadTask.urlSessionConfigure,
            delegate: nil,
            delegateQueue: nil
        )
        taskInfo = TaskInfo(src: downloadTask.url.absoluteURL.absoluteString, dest: downloadTask.destinationURL.absoluteURL.absoluteString, identifier: downloadTask.identifier)
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTTPChunkDownloadManager")
            .appendingPathComponent("\(taskInfo.identifier).downloading")
        taskInfoSavePath = tempDirectory.appendingPathComponent("info.json")
        if FileManager.default.fileExists(atPath: taskInfoSavePath.path) {
            do {
                taskInfo = try JSONDecoder().decode(TaskInfo.self, from: Data(contentsOf: taskInfoSavePath))
            } catch {
                LoggerProxy.WLog(tag: kLogTag, msg: "恢复任务信息失败")
            }
        }
        LoggerProxy.DLog(tag: kLogTag, msg: "init:\(self)")
    }

    deinit {
        LoggerProxy.DLog(tag: kLogTag, msg: "deinit:\(self)")
    }

    // MARK: - 公共接口

    public func start() {
        Task {
            LoggerProxy.ILog(tag: kLogTag, msg: "开始下载,\(state)")
            /// 这个需要启动task进行开始
            if state == .initialed {
                await update(state: .preparing)
                let startTask = Task {
                    await checkServerSupport()
                }
                activeTasks["start"] = startTask
            }
        }
    }

    /// 暂停下载
    public func pause() {
        Task {
            LoggerProxy.ILog(tag: kLogTag, msg: "暂停下载,\(state)")
            /// 下载中才能暂停
            if state.canPause {
                await update(state: .paused)
            }
            /// 不知道外面暂停多久，避免异常，直接取消下载task
            for chunkTask in chunkTasks {
                chunkTask.pauseDownload()
            }
        }
    }

    /// 恢复继续下载
    public func resume() {
        Task {
            LoggerProxy.ILog(tag: kLogTag, msg: "恢复下载:\(chunkAvailable),\(state),\(activeTasks.keys()),\(downloadTask.identifier)")
            if chunkAvailable {
                /// 暂停才能继续
                guard state.canResume else { return }
                LoggerProxy.ILog(tag: kLogTag, msg: "恢复chunk文件下载")
                await update(state: .downloading)
                for chunkTask in chunkTasks {
                    chunkTask.resumeDownload()
                }
                await checkAndStartAvailableChunksDownload()
            } else if state == .paused,
                      activeTasks.keys().contains(where: { $0 == downloadTask.identifier }) {
                LoggerProxy.ILog(tag: kLogTag, msg: "恢复普通文件下载")
                await update(state: .downloading)
            }
        }
    }

    /// 取消任务，只有完成/取消了，管理器才会停止，否则管理器会泄漏
    public func cancel() {
        Task {
            LoggerProxy.ILog(tag: kLogTag, msg: "取消下载,\(state)")
            if !state.isFinished {
                await update(state: .cancelled)
            }
            cancelAllDownloadTasks()
        }
    }

    /// 取消的任务不会删除临时目录，需要手动删除
    public func cleanup() {
        do {
            if FileManager.default.fileExists(atPath: tempDirectory.path) {
                try FileManager.default.removeItem(at: tempDirectory)
            }
        } catch {
            LoggerProxy.DLog(tag: kLogTag, msg: "Error cleaning up temporary directory: \(error.localizedDescription)")
        }
    }

    private func saveTaskInfo() throws {
        try JSONEncoder().encode(taskInfo).write(to: taskInfoSavePath)
    }

    /// 创建临时文件夹
    private func createTempDirectory() throws {
        if !FileManager.default.fileExists(atPath: tempDirectory.path) {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        }
        /// 创建分块是否，已经知道长度，这时候可以保存info信息
        taskInfo.totalBytes = totalBytes
        try? saveTaskInfo()
        LoggerProxy.DLog(tag: kLogTag, msg: "createTempDirectory:\(tempDirectory)")
    }

    /// 创建分块任务
    private func createChunkTasks() async {
        guard totalBytes > 0 else { return }

        var offset: Int64 = 0
        var tempChunkTasks: [Chunk] = []
        var index = 0
        while offset < totalBytes {
            let chunkSize = min(configuration.chunkSize, totalBytes - offset)
            let end = offset + chunkSize - 1
            let chunkTask = Chunk(
                identifier: "\(downloadTask.identifier)-\(index)[\(offset)~\(end)]",
                index: index,
                downloadTask: downloadTask,
                start: offset,
                end: end,
                downloadedBytes: 0,
                filePath: tempDirectory.appendingPathComponent("[\(index)]\(offset)-\(chunkSize).part"),
                isCompleted: false
            )
            tempChunkTasks.append(chunkTask)
            offset += chunkSize
            index += 1
        }

        chunkTasks = tempChunkTasks
        await checkLocalChunksStatus()
    }

    /// 检查本地分块
    private func checkLocalChunksStatus() async {
        var totalDownloaded: Int64 = 0

        for i in 0 ..< chunkTasks.count {
            let chunkTask = chunkTasks[i]
            let chunkPath = chunkTask.filePath.path
            if FileManager.default.fileExists(atPath: chunkPath) {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: chunkPath)
                    let fileSize = attributes[.size] as? Int64 ?? 0
                    if fileSize == chunkTasks[i].totalChunkSize {
                        chunkTasks[i].isCompleted = true
                        chunkTasks[i].downloadedBytes = fileSize
                        taskDownloadedBytes[chunkTask.identifier] = fileSize
                    } else if fileSize > 0 {
                        chunkTasks[i].downloadedBytes = fileSize
                        taskDownloadedBytes[chunkTask.identifier] = fileSize
                    } else {
                        try? FileManager.default.removeItem(atPath: chunkPath)
                        chunkTasks[i].downloadedBytes = 0
                        taskDownloadedBytes[chunkTask.identifier] = 0
                    }
                } catch {
                    try? FileManager.default.removeItem(atPath: chunkPath)
                    chunkTasks[i].downloadedBytes = 0
                }
            }
            totalDownloaded += chunkTasks[i].downloadedBytes
        }

        if totalBytes > 0 {
            await update(progress: DownloadProgress(downloadedBytes: totalDownloaded, totalBytes: totalBytes))
        } else {
            await update(progress: DownloadProgress(downloadedBytes: totalDownloaded, totalBytes: -1))
        }
    }

    /// 获取到完整大小，这时候更新一次进度
    private func updateTotalBytes(_ bytes: Int64) async {
        totalBytes = bytes
        await update(progress: DownloadProgress(downloadedBytes: 0, totalBytes: bytes))
    }

    /// 更新分块进度
    private func updateDownloadProgress(for identifier: String, bytes: Int64) async {
        taskDownloadedBytes[identifier] = bytes
        await updateProgressIfNeeded()
    }

    private func updateProgressIfNeeded() async {
        let totalDownloaded = taskDownloadedBytes.values.reduce(0, +)

        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdate) >= configuration.progressUpdateInterval else { return }
        lastProgressUpdate = now

        guard totalBytes > 0 else { return }

        await update(progress: DownloadProgress(timestamp: now.timeIntervalSince1970, downloadedBytes: totalDownloaded, totalBytes: totalBytes))
    }

    private func updateChunkStatus(at index: Int, completed: Bool, downloadedBytes: Int64) {
        guard chunkTasks.indices.contains(index) else { return }
        chunkTasks[index].isCompleted = completed
        chunkTasks[index].downloadedBytes = downloadedBytes
    }

    private func getNextAvailableChunks(maxCount: Int) -> [Chunk] {
        let currentActiveCount = activeTaskIndices.count
        let availableSlots = maxCount - currentActiveCount

        guard availableSlots > 0 else { return [] }

        var chunksToStart: [Chunk] = []
        for chunk in chunkTasks {
            if !chunk.isCompleted && !activeTaskIndices.contains(chunk.identifier) {
                chunksToStart.append(chunk)
                if chunksToStart.count >= availableSlots {
                    break
                }
            }
        }

        for chunk in chunksToStart {
            activeTaskIndices.insert(chunk.identifier)
        }

        return chunksToStart
    }

    private func markChunkComplete(for identifier: String) -> Bool {
        activeTaskIndices.remove(identifier)
        return chunkTasks.allSatisfy { $0.isCompleted }
    }

    // MARK: - 其他私有方法（简化后的版本）

//    private func buildRequest(method: String = "GET", headers: [String: String] = [:])async throws -> URLRequest {

//        var request = URLRequest(url: downloadTask.url)
//        request.httpMethod = method
//
//        for (key, value) in downloadTask.taskConfigure.headers {
//            request.setValue(value, forHTTPHeaderField: key)
//        }
//        for (key, value) in headers {
//            request.setValue(value, forHTTPHeaderField: key)
//        }
//
//        if let timeoutInterval = downloadTask.taskConfigure.timeoutInterval {
//            request.timeoutInterval = timeoutInterval
//        }
//
//        return request
//    }

    // 优先使用head获取文件长度
    private func checkServerSupport() async {
        LoggerProxy.DLog(tag: kLogTag, msg: "\(Date()):checkServerSupport:\(downloadTask.identifier)")
        do {
            // TODO: 检查info文件

            let (_, response) = try await session.data(for: downloadTask.buildRequest(method: "HEAD"))
            try Task.checkCancellation()
            await handleServerSupportResponse(response: response, error: nil, isHeadRequest: true)
        } catch is CancellationError {
            /// task 被取消
            LoggerProxy.WLog(tag: kLogTag, msg: "Cancel:\(downloadTask.identifier)")
        } catch {
            await handleServerSupportResponse(response: nil, error: error, isHeadRequest: true)
        }
    }

    // 使用get方式 获取文件长度
    private func checkServerSupportWithGet() async {
        do {
            let (_, response) = try await session.data(for: downloadTask.buildRequest(headers: ["Range": "bytes=0-1"]))
            await handleServerSupportResponse(response: response, error: nil, isHeadRequest: false)
        } catch {
            await handleServerSupportResponse(response: nil, error: error, isHeadRequest: false)
        }
    }

    /// 获取到文件长度后到操作
    private func handleServerSupportResponse(response: URLResponse?, error: Error?, isHeadRequest: Bool) async {
        LoggerProxy.DLog(tag: kLogTag, msg: "\(Date()):handleServerSupportResponse:\(downloadTask.identifier), resp=\(response),error=\(error)")

        if let error = error {
            await handleDownloadFailure(error: DownloadError.networkError(error.localizedDescription))
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            await handleDownloadFailure(error: DownloadError.invalidResponse)
            return
        }

        if isHeadRequest {
            let acceptsRanges = httpResponse.allHeaderFields["Accept-Ranges"] as? String
            let contentLength = httpResponse.allHeaderFields["Content-Length"] as? String
            let supportsRanges = acceptsRanges?.lowercased() == "bytes"
            let hasContentLength = contentLength != nil && Int64(contentLength!) ?? -1 > 0

            if supportsRanges,
               hasContentLength,
               let contentLength = contentLength,
               let contentLengthValue = Int64(contentLength) {
                await updateTotalBytes(contentLengthValue) // 直接调用，不需要 await
                await prepareForChunkDownload()
            } else {
                await checkServerSupportWithGet()
            }
        } else {
            let supportsRanges = httpResponse.statusCode == 206
            var fileSizeFromRange: Int64 = -1

            if let contentRange = httpResponse.allHeaderFields["Content-Range"] as? String {
                let components = contentRange.components(separatedBy: "/")
                if components.count > 1, let totalSize = Int64(components[1]) {
                    fileSizeFromRange = totalSize
                }
            }

            if supportsRanges && fileSizeFromRange > 0 {
                await updateTotalBytes(fileSizeFromRange) // 直接调用，不需要 await
                await prepareForChunkDownload()
            } else {
                await startNormalDownload()
            }
        }
    }

    /// 准备分块下载
    private func prepareForChunkDownload() async {
        guard totalBytes > 0 else {
            await handleDownloadFailure(error: DownloadError.serverNotSupported)
            return
        }

        do {
            chunkAvailable = true
            try createTempDirectory() // 直接调用，不需要 await
            await createChunkTasks() // 直接调用，不需要 await
            await update(state: .downloading) // 直接调用，不需要 await
            await checkAndStartAvailableChunksDownload()
        } catch {
            let chunkError: DownloadError
            if let ce = error as? DownloadError {
                chunkError = ce
            } else {
                chunkError = DownloadError(code: -1, description: error.localizedDescription)
            }
            await handleDownloadFailure(error: chunkError)
        }
    }

    private func startNormalDownload() async {
        await update(state: .downloading) // 直接调用，不需要 await
        do {
            let request = try await downloadTask.buildRequest()
            let taskKey = downloadTask.identifier
            /// 普通下载就是一次性的chunk
            let fullChunk = Chunk(identifier: downloadTask.identifier, index: 0, downloadTask: downloadTask, start: 0, end: -1, downloadedBytes: 0, filePath: downloadTask.destinationURL, isCompleted: false)
            let task = Task {
                await downloadChunk(fullChunk)
                self.activeTasks[taskKey] = nil
            }
            activeTasks[taskKey] = task
        } catch {
            await handleDownloadFailure(error: error)
        }
    }

    private func checkAndStartAvailableChunksDownload() async {
        LoggerProxy.DLog(tag: kLogTag, msg: "startNextAvailableChunks")

        // 下载中，准备中，才会开始下载新的分块
        guard state == .downloading || state == .preparing else { return }

        let chunksToStart = getNextAvailableChunks(maxCount: configuration.maxConcurrentChunks) // 直接调用

        LoggerProxy.DLog(tag: kLogTag, msg: "startNextAvailableChunks,chunksToStart=\(chunksToStart.count)")
        if chunksToStart.isEmpty {
            let allCompleted = chunkTasks.allSatisfy { $0.isCompleted }
            if allCompleted {
                await mergeChunks()
            }
        } else {
            for chunk in chunksToStart {
                await downloadChunk(chunk)
            }
        }
    }

    private func waitForResumeOrCancel() async throws {
        let subject = $state.filter({ $0 != .paused }).eraseToAnyPublisher()
        while state == .paused { // 直接调用，不需要 await
            for await _ in subject.values {
                break
            }
            LoggerProxy.ILog(tag: kLogTag, msg: "暂停中恢复:\(state)")
            if state == .cancelled { // 直接调用，不需要 await
                throw DownloadError.cancelled
            }
            try Task.checkCancellation()
        }
    }

//    func optimizedDownload(bytes: URLSession.AsyncBytes, fileHandle: FileHandle, identifier: String, totalDownloaded: inout Int64) async throws {
//        var buffer = Data()
//        buffer.reserveCapacity(configuration.bufferSize)
//
//        let chunkSize = min(8192, configuration.bufferSize) // 8KB 块大小
//        var tempChunk = Data()
//        tempChunk.reserveCapacity(chunkSize)
//
//        var processedBytes = 0
//        let statusCheckInterval = configuration.bufferSize // 每个缓冲区大小检查一次状态
//
//        for try await byte in bytes {
//            tempChunk.append(byte)
//            processedBytes += 1
//
//            // 当临时块达到大小或者需要检查状态时
//            if tempChunk.count >= chunkSize || processedBytes % statusCheckInterval == 0 {
//                // 状态检查
//                try Task.checkCancellation()
//
//                if state == .cancelled {
//                    throw DownloadError.cancelled
//                }
//
//                // 添加到主缓冲区
//                buffer.append(tempChunk)
//                tempChunk.removeAll(keepingCapacity: true)
//
//                // 写入文件如果缓冲区满了
//                if buffer.count >= configuration.bufferSize {
//                    try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
//                    totalDownloaded += Int64(buffer.count)
//                    buffer.removeAll(keepingCapacity: true)
//                }
//
//                // 处理暂停
//                if state == .paused {
//                    if !buffer.isEmpty {
//                        try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
//                        totalDownloaded += Int64(buffer.count)
//                        buffer.removeAll(keepingCapacity: true)
//                    }
//                    try await waitForResumeOrCancel()
//                }
//            }
//        }
//
//        // 处理剩余数据
//        if !tempChunk.isEmpty {
//            buffer.append(tempChunk)
//        }
//
//        if !buffer.isEmpty {
//            try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
//            totalDownloaded += Int64(buffer.count)
//        }
//    }

//    /// 普通下载，就是一次性下载全部
//    private func downloadNormalAsync(request: URLRequest) async {
//
//    }
//        LoggerProxy.DLog(tag: kLogTag, msg: "start downloadNormalAsync")
//        let identifier = downloadTask.identifier
//        let tempFile = downloadTask.destinationURL.appendingPathExtension(".downloading")
//        do {
//            let (bytes, response) = try await session.bytes(for: request)
//            try Task.checkCancellation()
//
//            guard let httpResponse = response as? HTTPURLResponse,
//                  httpResponse.statusCode == 200 else {
//                throw DownloadError.invalidResponse
//            }
//
//            let contentLength = httpResponse.allHeaderFields["Content-Length"] as? String
//            let expectedTotalBytes = contentLength.flatMap { Int64($0) } ?? -1
//            await updateTotalBytes(expectedTotalBytes) // 直接调用，不需要 await
//
//            let destinationDirectory = downloadTask.destinationURL.deletingLastPathComponent()
//            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
//            try? FileManager.default.removeItem(at: downloadTask.destinationURL)
//            FileManager.default.createFile(atPath: downloadTask.destinationURL.path, contents: nil)
//
//            let fileHandle = try FileHandle(forWritingTo: tempFile)
//            defer {
//                try? fileHandle.close()
//            }
//            var totalDownloaded: Int64 = 0
//            var buffer = Data()
//            try await optimizedDownload(bytes: bytes, fileHandle: fileHandle, identifier: identifier, totalDownloaded: &totalDownloaded)
    ////            for try await byte in bytes {
    ////                buffer.append(byte)
    ////
    ////                try Task.checkCancellation()
    ////
    ////                if state == .cancelled {
    ////                    throw DownloadError.cancelled
    ////                }
    ////
    ////                buffer.append(byte)
    ////
    ////                if buffer.count >= configuration.bufferSize {
    ////                    try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
    ////                    totalDownloaded += Int64(buffer.count)
    ////                    buffer.removeAll(keepingCapacity: true)
    ////                }
    ////
    ////                if state == .paused {
    ////                    if !buffer.isEmpty {
    ////                        try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
    ////                        totalDownloaded += Int64(buffer.count)
    ////                        buffer.removeAll(keepingCapacity: true)
    ////                    }
    ////                    try await waitForResumeOrCancel()
    ////                }
    ////            }
//
    ////            if !buffer.isEmpty {
    ////                try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
    ////                totalDownloaded += Int64(buffer.count)
    ////                buffer.removeAll()
    ////            }
//
//            LoggerProxy.DLog(tag: kLogTag, msg: "close file handler for normal download")
//
//            if expectedTotalBytes > 0, /// 已经有文件长度的前提
//               totalDownloaded != expectedTotalBytes {
//                throw DownloadError.corruptedChunk(identifier)
//            }
//            // 下载完成才重命名回去
//            try FileManager.default.moveItem(at: tempFile, to: downloadTask.destinationURL)
//            await handleDownloadCompletion()
//        } catch {
//            if FileManager.default.fileExists(atPath: tempFile.path) {
//                try? FileManager.default.removeItem(at: tempFile)
//            }
//            await handleNormalDownloadError(error)
//        }
//    }

//    private func writeBufferToFile(buffer: Data, fileHandle: FileHandle, identifier: String) async throws {
//        let deltaSize = Int64(buffer.count)
//        try fileHandle.write(contentsOf: buffer)
//        await updateDownloadProgress(for: identifier, bytes: deltaSize)
//        LoggerProxy.VLog(tag: kLogTag, msg: "write to file handler for download with: offset=\(progress.0) +  \(deltaSize)=\(progress.1) \(identifier)")
//    }

    private func handleNormalDownloadError(_ error: Error) async {
        let chunkError: DownloadError
        if let ce = error as? DownloadError {
            chunkError = ce
        } else {
            chunkError = DownloadError.from(error)
        }

        if case .cancelled = chunkError {
            return
        } else {
            await handleDownloadFailure(error: chunkError)
        }
    }

    private func openFileHandler(for chunkTask: Chunk) throws -> FileHandle {
        let fileHandle: FileHandle
        if chunkTask.downloadedBytes > 0 {
            fileHandle = try FileHandle(forWritingTo: chunkTask.filePath)
            try fileHandle.seekToEnd()
        } else {
            FileManager.default.createFile(atPath: chunkTask.filePath.path, contents: nil)
            fileHandle = try FileHandle(forWritingTo: chunkTask.filePath)
        }
        return fileHandle
    }

    private func downloadChunk(_ chunkTask: Chunk) async {
        LoggerProxy.DLog(tag: kLogTag, msg: "downloadChunk:\(chunkTask.identifier)")
        do {
            let startByte = chunkTask.start + chunkTask.downloadedBytes
            let endByte = chunkTask.end
            var headers: [String: String] = [:]
            if startByte >= 0 || endByte > 0 {
                var prefix = ""
                var suffix = ""
                if startByte >= 0 {
                    prefix = "\(startByte)"
                }
                if endByte > 0 {
                    suffix = "\(endByte)"
                }
                headers["Range"] = "bytes=\(prefix)-\(suffix)"
            }
            let request = try await downloadTask.buildRequest(headers: headers)
            let taskKey = chunkTask.identifier
            let task = Task {
                await self.downloadChunkAsync(request: request, chunk: chunkTask)
                self.activeTasks[taskKey] = nil
            }
            activeTasks[taskKey] = task
        } catch {
            await handleChunkError(error, for: chunkTask)
        }
    }

//    @concurrent
//    private func downloadChunkAsync(request: URLRequest, chunk: Chunk) async {
//        LoggerProxy.DLog(tag: kLogTag, msg: "start downloadChunkAsync--->:\(chunk.identifier)")
    ////        var taskFileHandle: FileHandle?
//        var downloadedBytes: Int64 = chunk.downloadedBytes
//        let identifier = chunk.identifier
//        do {
//            if await state == .cancelled {
//                return
//            }
//
//            let (bytes, response) = try await session.bytes(for: request)
//            try Task.checkCancellation()
//
//            guard let httpResponse = response as? HTTPURLResponse,
//                  httpResponse.statusCode == 206 || httpResponse.statusCode == 200 else {
//                throw DownloadError.invalidResponse
//            }
//
//            let fileHandle = try await openFileHandler(for: chunk)
//            defer {
//                try? fileHandle.close()
//            }
//
//            // 初始化任务下载字节数
    ////            await updateDownloadProgress(for: identifier, addedBytes: chunk.downloadedBytes) // 直接调用，不需要 await
//            try await optimizedDownload(bytes: bytes, fileHandle: fileHandle, identifier: identifier, totalDownloaded: &downloadedBytes)
    ////            var buffer = Data()
    ////            for try await byte in bytes {
    ////                try Task.checkCancellation()
    ////
    ////                if await state == .cancelled {
    ////                    throw DownloadError.cancelled
    ////                }
    ////                /// 其他下载失败
    ////                if await state.isFailed {
    ////                    // 直接不玩了……
    ////                    LoggerProxy.DLog(tag: kLogTag, msg: "有其他chunk下载失败，直接取消下载任务")
    ////                    return
    ////                }
    ////
    ////                buffer.append(byte)
    ////                if await state == .paused {
    ////                    if !buffer.isEmpty {
    ////                        try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
    ////                        downloadedBytes += Int64(buffer.count)
    ////                        buffer.removeAll(keepingCapacity: true)
    ////                    }
    ////
    ////                    try await waitForResumeOrCancel()
    ////                }
    ////                if buffer.count >= configuration.bufferSize { // 64k 一次保存
    ////                    try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
    ////                    downloadedBytes += Int64(buffer.count)
    ////                    buffer.removeAll(keepingCapacity: true)
    ////                }
    ////            }
    ////
    ////            // 写入剩余缓冲区数据
    ////            if !buffer.isEmpty {
    ////                try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
    ////                downloadedBytes += Int64(buffer.count)
    ////                buffer.removeAll()
    ////            }
//
//            // 验证下载的字节数
//            let expectedBytes = chunk.totalChunkSize
//            if downloadedBytes != expectedBytes {
//                LoggerProxy.DLog(tag: kLogTag, msg: "验证下载结果失败:\(downloadedBytes)!=\(expectedBytes) , \(request.allHTTPHeaderFields),response=>\(response)")
//                throw DownloadError.corruptedChunk(chunk.identifier)
//            }
//
//            LoggerProxy.DLog(tag: kLogTag, msg: "close file handler:\(identifier)")
//
//            // 更新分片状态并处理完成
//            await updateChunkStatus(at: chunk.index, completed: true, downloadedBytes: downloadedBytes) // 直接调用，不需要 await
//            await onChunkComplete(for: chunk)
//        } catch {
//            await handleChunkError(error, for: chunk)
//        }
//    }
    /// 使用 DownloadTask 方式下载分块
    private func downloadChunkAsync(request: URLRequest, chunk: Chunk) async {
        LoggerProxy.DLog(tag: kLogTag, msg: "start downloadChunkWithDownloadTask--->:\(chunk.identifier)")

        do {
            if await state == .cancelled {
                return
            }

            // 设置进度回调
            chunk.onProgressUpdate = { [weak self] chunk, downloaded, _ in
                Task {
                    await self?.updateDownloadProgress(for: chunk.identifier, bytes: downloaded)
                }
            }
            // 开始下载并等待完成
            try await chunk.startDownload(with: session, request: request)

            // 验证下载的文件大小
            let downloadedFileSize = try FileManager.default.attributesOfItem(atPath: chunk.filePath.path)[.size] as? Int64 ?? 0
            let expectedBytes = chunk.totalChunkSize

            if downloadedFileSize != expectedBytes {
                LoggerProxy.DLog(tag: kLogTag, msg: "验证下载结果失败:\(downloadedFileSize)!=\(expectedBytes) , \(request.allHTTPHeaderFields)")
                throw DownloadError.corruptedChunk(chunk.identifier)
            }

            // 将下载的临时文件移动到目标位置
//            try await moveChunkToFinalLocation(from: tempLocation, chunk: chunk)

            LoggerProxy.DLog(tag: kLogTag, msg: "Chunk download completed: \(chunk.identifier)")

            // 更新分块状态
            await updateChunkStatus(at: chunk.index, completed: true, downloadedBytes: downloadedFileSize)
            await onChunkComplete(for: chunk)
        } catch {
            LoggerProxy.DLog(tag: kLogTag, msg: "Chunk download failed: \(chunk.identifier), error: \(error)")
            await handleChunkError(error, for: chunk)
        }
    }

    /// 将分块文件移动到最终位置

    private func onChunkComplete(for chunk: Chunk) async {
        let allCompleted = markChunkComplete(for: chunk.identifier) // 直接调用，不需要 await

        let state = self.state
        guard state == .downloading || state == .preparing else { return }

        if allCompleted {
            await mergeChunks()
        } else {
            await checkAndStartAvailableChunksDownload()
        }
    }

    private func mergeChunks() async {
        do {
            try await mergeChunksToFile()
            cleanup() // 直接调用，不需要 await
            await handleDownloadCompletion()
        } catch {
            let chunkError: DownloadError
            if let ce = error as? DownloadError {
                chunkError = ce
            } else {
                chunkError = DownloadError.from(error)
            }
            await handleDownloadFailure(error: chunkError)
        }
    }

    private func mergeChunksToFile() async throws {
        await update(state: .merging) // 直接调用，不需要 await

        let tempMergeFile = tempDirectory.appendingPathComponent("final_merged_file.tmp")
        let chunkFiles = chunkTasks.sorted(by: { $0.start < $1.start }).map({ $0.filePath.path })

        // 使用 256k~4m 块，进行文件合并
        let bufferSize = Int(min(max(configuration.chunkSize, 256 * 1024), 4 * 1024 * 1024)) // 256~1m

        /// 删除
        if FileManager.default.fileExists(atPath: tempMergeFile.path) {
            try FileManager.default.removeItem(at: tempMergeFile)
        }
        let dir = downloadTask.destinationURL.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: downloadTask.destinationURL.deletingLastPathComponent().path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try checkDiskSpace(requiredSpace: totalBytes, destinationURL: dir)

        // 校验分块文件大小是否都是预期的
        for chunkTask in chunkTasks {
            try validateChunk(chunkTask)
        }

        // 使用 open方式合并，更加高效
        try mergeFilesWithPOSIXOpen(sourceFilePaths: chunkFiles, destinationFilePath: tempMergeFile.path, bufferSize: bufferSize)

//        // 创建合并文件
//        FileManager.default.createFile(atPath: tempMergeFile.path, contents: nil)
//        let fileHandle = try FileHandle(forWritingTo: tempMergeFile)
//        defer { try? fileHandle.close() }
//
//        /// 按照开始顺序，写入
//        for chunkTask in chunkTasks.sorted(by: { $0.start < $1.start }) {
//            let chunkHandle = try FileHandle(forReadingFrom: chunkTask.filePath)
//            defer { try? chunkHandle.close() }
//
//            try autoreleasepool {
//                while let data = try chunkHandle.read(upToCount: bufferSize) {
//                    try fileHandle.write(contentsOf: data)
//                }
//            }
//        }

        let destinationDirectory = downloadTask.destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        // 如果目标文件存在，删除并重命名
        LoggerProxy.DLog(tag: kLogTag, msg: "merge move from:\(tempMergeFile) to:\(downloadTask.destinationURL)")
        if FileManager.default.fileExists(atPath: downloadTask.destinationURL.path) {
            try FileManager.default.removeItem(at: downloadTask.destinationURL)
        }
        try FileManager.default.moveItem(at: tempMergeFile, to: downloadTask.destinationURL)
    }

    // 定义一个错误枚举，以便更清晰地表示可能发生的错误
    enum POSIXFileMergeError: Error {
        case cannotOpenFile(String, Int32) // 文件路径, errno
        case cannotCreateFile(String, Int32)
        case readError(String, Int32)
        case writeError(String, Int32)
        case partialWriteError(String, Int, Int) // 文件路径, 期望写入字节数, 实际写入字节数
    }

    /// 使用 POSIX open/read/write 接口高效合并多个文件。
    /// - Parameters:
    ///   - sourceFilePaths: 包含所有源文件路径的数组。
    ///   - destinationFilePath: 合并后的目标文件路径。
    ///   - bufferSize: 用于读写操作的缓冲区大小（字节）。默认为 64KB。
    /// - Throws: 如果文件操作失败，则抛出 POSIXFileMergeError。
    func mergeFilesWithPOSIXOpen(sourceFilePaths: [String], destinationFilePath: String, bufferSize: Int = 64 * 1024) throws {
        let fileManager = FileManager.default

        // 1. 确保目标文件不存在，如果存在则删除
        if fileManager.fileExists(atPath: destinationFilePath) {
            do {
                try fileManager.removeItem(atPath: destinationFilePath)
            } catch {
                LoggerProxy.ELog(tag: kLogTag, msg: "警告: 无法删除现有目标文件 \(destinationFilePath): \(error.localizedDescription)")
                // 可以选择在这里抛出错误，或继续尝试写入（这会覆盖文件）
            }
        }

        // 2. 打开或创建目标文件以便写入
        // O_WRONLY: 只写模式
        // O_CREAT: 如果文件不存在则创建
        // O_TRUNC: 如果文件存在则清空其内容
        // S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH: 设置文件权限 (用户读写，组和其他只读)
        let destFD = open(destinationFilePath, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        if destFD == -1 {
            throw POSIXFileMergeError.cannotCreateFile(destinationFilePath, errno)
        }

        // 确保在函数退出时关闭目标文件描述符
        defer {
            close(destFD)
        }

        // 3. 分配一个预分配的缓冲区
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: MemoryLayout<UInt8>.alignment)
        // 确保在函数退出时释放这块内存
        defer {
            buffer.deallocate()
        }

        // 4. 遍历源文件并逐一合并
        for sourcePath in sourceFilePaths {
            LoggerProxy.DLog(tag: kLogTag, msg: "正在合并文件: \(sourcePath)")

            // 打开源文件进行读取
            let sourceFD = open(sourcePath, O_RDONLY)
            let errcode = errno
            if sourceFD == -1 {
                LoggerProxy.WLog(tag: kLogTag, msg: "警告: 无法打开源文件 \(sourcePath)，跳过。错误: \(String(cString: strerror(errcode)))")
                throw POSIXFileMergeError.cannotOpenFile(sourcePath, errcode)
            }

            // 确保在处理完当前源文件后关闭其文件描述符
            defer {
                close(sourceFD)
            }

            do {
                while true {
                    // 从源文件读取数据到缓冲区
                    // read 函数返回实际读取的字节数，-1 表示错误，0 表示文件结束
                    let bytesRead = read(sourceFD, buffer.baseAddress!, bufferSize)

                    if bytesRead == -1 {
                        throw POSIXFileMergeError.readError(sourcePath, errno)
                    }

                    if bytesRead == 0 {
                        // 读取到文件末尾
                        break
                    }

                    // 将缓冲区中的数据写入目标文件
                    let bytesWritten = write(destFD, buffer.baseAddress!, bytesRead)

                    if bytesWritten == -1 {
                        throw POSIXFileMergeError.writeError(destinationFilePath, errno)
                    }

                    if bytesWritten != bytesRead {
                        // 写入的字节数少于读取的字节数，表示部分写入或错误
                        throw POSIXFileMergeError.partialWriteError(destinationFilePath, bytesRead, bytesWritten)
                    }
                }
            } catch {
                LoggerProxy.ELog(tag: kLogTag, msg: "处理文件时发生错误 for \(sourcePath): \(error.localizedDescription)")
                // 可以选择抛出错误或继续处理下一个文件
            }
        }

        LoggerProxy.DLog(tag: kLogTag, msg: "所有文件合并完成到: \(destinationFilePath)")
    }

    private func checkDiskSpace(requiredSpace: Int64, destinationURL: URL) throws {
        if DiskSpaceManager.shared.getAvailableDiskSpace(for: destinationURL.path) < requiredSpace {
            throw DownloadError.insufficientDiskSpace
        }
    }

    private func validateChunk(_ chunk: Chunk) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: chunk.filePath.path) else {
            throw DownloadError.corruptedChunk(chunk.identifier)
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: chunk.filePath.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            if fileSize != chunk.totalChunkSize {
                throw DownloadError.corruptedChunk(chunk.identifier)
            }
        } catch {
            throw DownloadError.corruptedChunk(chunk.identifier)
        }
    }

    private func handleDownloadCompletion() async {
        let fullSize: Int64
        if totalBytes > 0 {
            fullSize = totalBytes
        } else {
            fullSize = taskDownloadedBytes.values.reduce(0, +)
        }

        await update(progress: DownloadProgress(downloadedBytes: fullSize, totalBytes: fullSize))
        await update(state: .completed) // 直接调用，不需要 await
    }

    private func handleDownloadFailure(error: any Error) async {
        LoggerProxy.ELog(tag: kLogTag, msg: "handleDownloadFailure:\(error)")
        let currentState = state // 直接调用，不需要 await
        /// 已经报告了失败，不重复报
        if currentState.isFailed {
            return
        }
        if currentState != .completed && currentState != .cancelled {
            await update(state: .failed(DownloadError.from(error))) // 直接调用，不需要 await
        }
        /// 异常了，取消所有其他下载
        cancelAllDownloadTasks()
    }

    private func handleChunkError(_ error: Error, for chunk: Chunk, funcName: StaticString = #function, line: Int = #line) async {
        LoggerProxy.ELog(tag: kLogTag, msg: "handler chunk error:\(error)", funcName: funcName, line: line)
        let chunkError: DownloadError
        if let ce = error as? DownloadError {
            chunkError = ce
        } else {
            chunkError = DownloadError.from(error)
        }

        if case .cancelled = chunkError {
            await onChunkComplete(for: chunk)
        } else {
            await handleDownloadFailure(error: chunkError)
        }
    }

    private func cancelAllDownloadTasks() {
        activeTasks.values().forEach { task in
            if !task.isCancelled {
                task.cancel()
            }
        }
        session.invalidateAndCancel()
        session = URLSession.shared
    }
}
