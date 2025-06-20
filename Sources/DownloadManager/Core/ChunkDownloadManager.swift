import Combine
import ConcurrencyCollection
import CryptoKit
import Foundation
import LoggerProxy

fileprivate let kLogTag = "ChunkDownloadManager"

/// 下载代理
public protocol ChunkDownloadManagerDelegate: AnyObject, Sendable {
    func chunkDownloadManager(_ manager: ChunkDownloadManager, didCompleteWith task: DownloadTask)
    func chunkDownloadManager(_ manager: ChunkDownloadManager, task: DownloadTask, didUpdateProgress progress: (Int64, Int64))
    func chunkDownloadManager(_ manager: ChunkDownloadManager, task: DownloadTask, didUpdateState state: DownloadState)
    func chunkDownloadManager(_ manager: ChunkDownloadManager, task: DownloadTask, didFailWithError error: Error)
}

/// 分块下载配置
public struct ChunkConfiguration: Sendable {
    public let chunkSize: Int64
    public let maxConcurrentChunks: Int
    public let progressUpdateInterval: TimeInterval
    public let bufferSize: Int

    public init(chunkSize: Int64, maxConcurrentChunks: Int, progressUpdateInterval: TimeInterval = 0.1, bufferSize: Int = 16 * 1024) {
        self.chunkSize = chunkSize
        self.maxConcurrentChunks = maxConcurrentChunks
        self.progressUpdateInterval = progressUpdateInterval
        self.bufferSize = bufferSize
    }
}

/// 分块任务
private struct ChunkTask: Sendable {
    let identifier: String
    let index: Int
    let downloadTask: any DownloadTaskProtocol
    let start: Int64
    let end: Int64
    var downloadedBytes: Int64
    var filePath: URL
    var isCompleted: Bool

    var totalChunkSize: Int64 {
        end - start + 1
    }
}

/// 分块下载错误
public enum ChunkDownloadError: Error, LocalizedError, Sendable {
    case networkError(String)
    case fileSystemError(String)
    case serverNotSupported
    case insufficientDiskSpace
    case corruptedChunk(String)
    case invalidResponse
    case timeout
    case cancelled
    case unknown(Error)

    public var errorDescription: String? {
        switch self {
        case let .networkError(message):
            return "网络错误: \(message)"
        case let .fileSystemError(message):
            return "文件系统错误: \(message)"
        case .serverNotSupported:
            return "服务器不支持分片下载或无法获取文件大小"
        case .insufficientDiskSpace:
            return "磁盘空间不足"
        case let .corruptedChunk(index):
            return "分片 \(index) 损坏或不完整"
        case .invalidResponse:
            return "服务器返回无效响应"
        case .timeout:
            return "下载超时"
        case .cancelled:
            return "下载已取消"
        case let .unknown(error):
            return "未知错误: \(error.localizedDescription)"
        }
    }

    public var errorCode: Int {
        switch self {
        case .networkError: return 0x2001
        case .fileSystemError: return 0x2002
        case .serverNotSupported: return 0x2003
        case .insufficientDiskSpace: return 0x2004
        case .corruptedChunk: return 0x2005
        case .invalidResponse: return 0x2006
        case .timeout: return 0x2007
        case .cancelled: return 0x2008
        case .unknown: return 0x20FF
        }
    }
}

/// 合并后的下载管理器 Actor
public actor ChunkDownloadManager {
    /// 下载任务
    private let downloadTask: DownloadTask
    /// 分块配置
    private let configuration: ChunkConfiguration
    /// 下载session
    private let session: URLSession
    /// 并发任务存储
    private let activeTasks = ConcurrentDictionary<String, Task<Void, Never>>()
    /// 分块任务
    private var chunkTasks: [ChunkTask] = []
    /// 正在下载的分块
    private var activeTaskIndices: Set<String> = []
    /// 下载的临时目录，完成后会删除
    private var tempDirectory: URL?
    /// 完整大小
    private var totalBytes: Int64 = -1
    /// 已经下载的大小
    private var taskDownloadedBytes: [String: Int64] = [:]
    /// 上一次进度更新时间
    private var lastProgressUpdate: Date = .distantPast
    /// 当前下载器状态，不直接关联task，避免被多个task关联
    public var state: DownloadState = .initialed
    /// 检查过可以分块
    public var chunkAvailable: Bool = false
    /// 更新进度
    private func update(progress: (Int64, Int64)) {
        downloadTask.progressSubject.send(progress)
        delegate?.chunkDownloadManager(self, task: downloadTask, didUpdateProgress: progress)
    }

    /// 更新状态
    private func update(state: DownloadState) {
        LoggerProxy.DLog(tag: kLogTag, msg: "update(state:\(state))")
        self.state = state
        downloadTask.stateSubject.send(state)
        delegate?.chunkDownloadManager(self, task: downloadTask, didUpdateState: state)
        if case .completed = state {
            delegate?.chunkDownloadManager(self, didCompleteWith: downloadTask)
        } else if case let .failed(downloadError) = state {
            delegate?.chunkDownloadManager(self, task: downloadTask, didFailWithError: downloadError)
        }
    }

    private weak var delegate: ChunkDownloadManagerDelegate?
    var cancellable: [AnyCancellable] = []

    // MARK: - 初始化

    public init(downloadTask: DownloadTask, configuration: ChunkConfiguration, delegate: ChunkDownloadManagerDelegate) {
        self.downloadTask = downloadTask
        self.configuration = configuration
        self.delegate = delegate
        session = URLSession(
            configuration: downloadTask.taskConfigure.urlSessionConfigure(),
            delegate: nil,
            delegateQueue: nil
        )
        LoggerProxy.DLog(tag: kLogTag, msg: "init:\(self)")
    }

    deinit {
        LoggerProxy.DLog(tag: kLogTag, msg: "deinit:\(self)")
    }

    // MARK: - 公共接口

    public func start() {
        LoggerProxy.ILog(tag: kLogTag, msg: "开始下载,\(state)")
        /// 这个需要启动task进行开始
        if state == .initialed {
            update(state: .preparing)
            let startTask = Task {
                await checkServerSupport()
            }
            activeTasks["start"] = startTask
        }
    }

    /// 暂停下载
    public func pause() {
        LoggerProxy.ILog(tag: kLogTag, msg: "暂停下载,\(state)")
        /// 下载中才能暂停
        if state.canPause {
            update(state: .paused)
        }
    }

    /// 恢复继续下载
    public func resume() {
        LoggerProxy.ILog(tag: kLogTag, msg: "恢复下载:\(chunkAvailable),\(state),\(activeTasks.keys()),\(downloadTask.identifier)")
        if chunkAvailable {
            /// 暂停才能继续
            guard state.canResume else { return }
            LoggerProxy.ILog(tag: kLogTag, msg: "恢复chunk文件下载")
            update(state: .downloading)
            checkAndStartAvailableChunksDownload()
        } else if state == .paused,
                  activeTasks.keys().contains(where: { $0 == downloadTask.identifier }) {
            LoggerProxy.ILog(tag: kLogTag, msg: "恢复普通文件下载")
            update(state: .downloading)
        }
    }

    /// 取消任务，只有完成/取消了，管理器才会停止，否则管理器会泄漏
    public func cancel() {
        LoggerProxy.ILog(tag: kLogTag, msg: "取消下载,\(state)")
        update(state: .cancelled)
        cancelAllDownloadTasks()
    }

    /// 取消的任务不会删除临时目录，需要手动删除
    public func cleanup() {
        if let tempDir = tempDirectory {
            do {
                try FileManager.default.removeItem(at: tempDir)
                tempDirectory = nil
            } catch {
                LoggerProxy.DLog(tag: kLogTag, msg: "Error cleaning up temporary directory: \(error.localizedDescription)")
            }
        }
    }

    /// 创建临时文件夹
    private func createTempDirectory() throws {
        let taskSha256 = downloadTask.identifier
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadManagerChunks")
            .appendingPathComponent("\(taskSha256).downloading")
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        }
        try? JSONSerialization
            .data(withJSONObject: ["src": downloadTask.url.absoluteString,
                                   "dest": downloadTask.destinationURL.absoluteString,
                                   "sha256": taskSha256]
            ).write(to: tempDir.appendingPathComponent("info.json"))

        tempDirectory = tempDir
        LoggerProxy.DLog(tag: kLogTag, msg: "createTempDirectory:\(tempDir)")
    }

    /// 创建分块任务
    private func createChunkTasks() {
        guard let tempDir = tempDirectory, totalBytes > 0 else { return }

        var offset: Int64 = 0
        var tempChunkTasks: [ChunkTask] = []
        var index = 0
        while offset < totalBytes {
            let chunkSize = min(configuration.chunkSize, totalBytes - offset)
            let end = offset + chunkSize - 1
            let chunkTask = ChunkTask(
                identifier: "\(downloadTask.identifier)-\(index)[\(offset)~\(end)]",
                index: index,
                downloadTask: downloadTask,
                start: offset,
                end: end,
                downloadedBytes: 0,
                filePath: tempDir.appendingPathComponent("[\(index)]\(offset)-\(chunkSize).part"),
                isCompleted: false
            )
            tempChunkTasks.append(chunkTask)
            offset += chunkSize
            index += 1
        }

        chunkTasks = tempChunkTasks
        checkLocalChunksStatus()
    }

    /// 检查本地分块
    private func checkLocalChunksStatus() {
        var totalDownloaded: Int64 = 0

        for i in 0 ..< chunkTasks.count {
            let chunkPath = chunkTasks[i].filePath.path
            if FileManager.default.fileExists(atPath: chunkPath) {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: chunkPath)
                    let fileSize = attributes[.size] as? Int64 ?? 0
                    if fileSize == chunkTasks[i].totalChunkSize {
                        chunkTasks[i].isCompleted = true
                        chunkTasks[i].downloadedBytes = fileSize
                    } else if fileSize > 0 {
                        chunkTasks[i].downloadedBytes = fileSize
                    } else {
                        try? FileManager.default.removeItem(atPath: chunkPath)
                        chunkTasks[i].downloadedBytes = 0
                    }
                } catch {
                    try? FileManager.default.removeItem(atPath: chunkPath)
                    chunkTasks[i].downloadedBytes = 0
                }
            }
            totalDownloaded += chunkTasks[i].downloadedBytes
        }

        if totalBytes > 0 {
            update(progress: (totalDownloaded, totalBytes))
        } else {
            update(progress: (totalDownloaded, -1))
        }
    }

    /// 获取到完整大小，这时候更新一次进度
    private func updateTotalBytes(_ bytes: Int64) {
        totalBytes = bytes
        update(progress: (0, totalBytes))
    }

    /// 更新分块进度
    private func updateDownloadProgress(for identifier: String, addedBytes: Int64) {
        if let currentBytes = taskDownloadedBytes[identifier] {
            taskDownloadedBytes[identifier] = currentBytes + addedBytes
        } else {
            taskDownloadedBytes[identifier] = addedBytes
        }
        updateProgressIfNeeded()
    }

    private func updateProgressIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdate) >= configuration.progressUpdateInterval else { return }
        lastProgressUpdate = now

        let totalDownloaded = taskDownloadedBytes.values.reduce(0, +)
        guard totalBytes > 0 else { return }

        update(progress: (totalDownloaded, totalBytes))
    }

    private func updateChunkStatus(at index: Int, completed: Bool, downloadedBytes: Int64) {
        guard chunkTasks.indices.contains(index) else { return }
        chunkTasks[index].isCompleted = completed
        chunkTasks[index].downloadedBytes = downloadedBytes
    }

    private func getNextAvailableChunks(maxCount: Int) -> [ChunkTask] {
        let currentActiveCount = activeTaskIndices.count
        let availableSlots = maxCount - currentActiveCount

        guard availableSlots > 0 else { return [] }

        var chunksToStart: [ChunkTask] = []
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

    private func buildRequest(method: String = "GET", headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: downloadTask.url)
        request.httpMethod = method

        for (key, value) in downloadTask.taskConfigure.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let timeoutInterval = downloadTask.taskConfigure.timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }

        return request
    }

    // 优先使用head获取文件长度
    private func checkServerSupport() async {
        LoggerProxy.DLog(tag: kLogTag, msg: "\(Date()):checkServerSupport:\(downloadTask.identifier)")
        do {
            let (_, response) = try await session.data(for: buildRequest(method: "HEAD"))
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
            let (_, response) = try await session.data(for: buildRequest(headers: ["Range": "bytes=0-1"]))
            await handleServerSupportResponse(response: response, error: nil, isHeadRequest: false)
        } catch {
            await handleServerSupportResponse(response: nil, error: error, isHeadRequest: false)
        }
    }

    /// 获取到文件长度后到操作
    private func handleServerSupportResponse(response: URLResponse?, error: Error?, isHeadRequest: Bool) async {
        LoggerProxy.DLog(tag: kLogTag, msg: "\(Date()):handleServerSupportResponse:\(downloadTask.identifier), resp=\(response),error=\(error)")

        if let error = error {
            await handleDownloadFailure(error: ChunkDownloadError.networkError(error.localizedDescription))
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            await handleDownloadFailure(error: ChunkDownloadError.invalidResponse)
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
                updateTotalBytes(contentLengthValue) // 直接调用，不需要 await
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
                updateTotalBytes(fileSizeFromRange) // 直接调用，不需要 await
                await prepareForChunkDownload()
            } else {
                await startNormalDownload()
            }
        }
    }

    /// 准备分块下载
    private func prepareForChunkDownload() async {
        guard totalBytes > 0 else {
            await handleDownloadFailure(error: ChunkDownloadError.serverNotSupported)
            return
        }

        do {
            chunkAvailable = true
            try createTempDirectory() // 直接调用，不需要 await
            createChunkTasks() // 直接调用，不需要 await
            update(state: .downloading) // 直接调用，不需要 await
            checkAndStartAvailableChunksDownload()
        } catch {
            let chunkError: ChunkDownloadError
            if let ce = error as? ChunkDownloadError {
                chunkError = ce
            } else {
                chunkError = .unknown(error)
            }
            await handleDownloadFailure(error: chunkError)
        }
    }

    private func startNormalDownload() async {
        update(state: .downloading) // 直接调用，不需要 await
        let request = buildRequest()
        let taskKey = downloadTask.identifier
        let task = Task {
            await self.downloadNormalAsync(request: request)
            self.activeTasks[taskKey] = nil
        }
        activeTasks[taskKey] = task
    }

    private func checkAndStartAvailableChunksDownload() {
        LoggerProxy.DLog(tag: kLogTag, msg: "startNextAvailableChunks")

        // 下载中，准备中，才会开始下载新的分块
        guard state == .downloading || state == .preparing else { return }

        let chunksToStart = getNextAvailableChunks(maxCount: configuration.maxConcurrentChunks) // 直接调用

        LoggerProxy.DLog(tag: kLogTag, msg: "startNextAvailableChunks,chunksToStart=\(chunksToStart.count)")

        for chunk in chunksToStart {
            downloadChunk(chunk)
        }
    }

    /// 普通下载，就是一次性下载全部
    private func downloadNormalAsync(request: URLRequest) async {
        LoggerProxy.DLog(tag: kLogTag, msg: "start downloadNormalAsync")
        var taskFileHandle: FileHandle?
        let identifier = downloadTask.identifier
        do {
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw ChunkDownloadError.invalidResponse
            }

            let contentLength = httpResponse.allHeaderFields["Content-Length"] as? String
            let expectedTotalBytes = contentLength.flatMap { Int64($0) } ?? -1
            updateTotalBytes(expectedTotalBytes) // 直接调用，不需要 await

            let destinationDirectory = downloadTask.destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: downloadTask.destinationURL)
            FileManager.default.createFile(atPath: downloadTask.destinationURL.path, contents: nil)

            let fileHandle = try FileHandle(forWritingTo: downloadTask.destinationURL)
            taskFileHandle = fileHandle

            var totalDownloaded: Int64 = 0
            var buffer = Data()

            for try await byte in bytes {
                try Task.checkCancellation()

                if state == .cancelled {
                    throw ChunkDownloadError.cancelled
                }

                buffer.append(byte)

                if buffer.count >= configuration.bufferSize {
                    try writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
                    totalDownloaded += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }

                if state == .paused {
                    let cancelSubject = PassthroughSubject<Void, Never>()
                    var events = [AnyCancellable]()
                    let subject = downloadTask.stateSubject.filter({
                        $0 != .paused
                    }).map({ _ in () }).merge(with: cancelSubject)
                    while state == .paused { // 直接调用，不需要 await
                        if !buffer.isEmpty {
                            try writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
                            totalDownloaded += Int64(buffer.count)
                            buffer.removeAll(keepingCapacity: true)
                        }

                        await withTaskCancellationHandler {
                            for await _ in subject.values {
                                LoggerProxy.ILog(tag: kLogTag, msg: "暂停中恢复……")
                                break
                            }
                        } onCancel: {
                            cancelSubject.send(())
                        }
                        LoggerProxy.ILog(tag: kLogTag, msg: "暂停中恢复:\(state)")
                        if state == .cancelled { // 直接调用，不需要 await
                            throw ChunkDownloadError.cancelled
                        }
                        try Task.checkCancellation()
                    }
                }
            }

            if !buffer.isEmpty {
                try writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
                totalDownloaded += Int64(buffer.count)
                buffer.removeAll()
            }

            LoggerProxy.DLog(tag: kLogTag, msg: "close file handler for normal download")
            try? fileHandle.close()

            if expectedTotalBytes > 0, /// 已经有文件长度的前提
               totalDownloaded != expectedTotalBytes {
                throw ChunkDownloadError.corruptedChunk(identifier)
            }

            await handleDownloadCompletion()
        } catch {
            try? taskFileHandle?.close()
            await handleNormalDownloadError(error)
        }
    }

    private func writeBufferToFile(buffer: Data, fileHandle: FileHandle, identifier: String) throws {
        let deltaSize = Int64(buffer.count)
        try fileHandle.write(contentsOf: buffer)
        updateDownloadProgress(for: identifier, addedBytes: deltaSize)
        LoggerProxy.DLog(tag: kLogTag, msg: "write to file handler for download with:[\(deltaSize)] \(identifier)")
    }

    private func handleNormalDownloadError(_ error: Error) async {
        let chunkError: ChunkDownloadError
        if let ce = error as? ChunkDownloadError {
            chunkError = ce
        } else {
            chunkError = .unknown(error)
        }

        if case .cancelled = chunkError {
            return
        } else {
            await handleDownloadFailure(error: chunkError)
        }
    }

    private func openFileHandler(for chunkTask: ChunkTask) throws -> FileHandle {
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

    private func downloadChunk(_ chunkTask: ChunkTask) {
        LoggerProxy.DLog(tag: kLogTag, msg: "downloadChunk:\(chunkTask.identifier)")

        var request = URLRequest(url: downloadTask.url)
        let startByte = chunkTask.start + chunkTask.downloadedBytes
        let endByte = chunkTask.end
        request.setValue("bytes=\(startByte)-\(endByte)", forHTTPHeaderField: "Range")

        for (key, value) in downloadTask.taskConfigure.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let taskKey = chunkTask.identifier
        let task = Task {
            await self.downloadChunkAsync(request: request, chunk: chunkTask)
            self.activeTasks[taskKey] = nil
        }
        activeTasks[taskKey] = task
    }

    private func downloadChunkAsync(request: URLRequest, chunk: ChunkTask) async {
        LoggerProxy.DLog(tag: kLogTag, msg: "start downloadChunkAsync--->:\(chunk.identifier)")
        var taskFileHandle: FileHandle?
        var downloadedBytes: Int64 = chunk.downloadedBytes
        let identifier = chunk.identifier
        do {
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 206 || httpResponse.statusCode == 200 else {
                throw ChunkDownloadError.invalidResponse
            }

            let fileHandle = try openFileHandler(for: chunk)
            defer {
                try? fileHandle.close()
            }
            taskFileHandle = fileHandle

            // 初始化任务下载字节数
            updateDownloadProgress(for: identifier, addedBytes: chunk.downloadedBytes) // 直接调用，不需要 await

            var buffer = Data()
            for try await byte in bytes {
                try Task.checkCancellation()

                if state == .cancelled {
                    throw ChunkDownloadError.cancelled
                }
                /// 其他下载失败
                if state.isFailed {
                    // 直接不玩了……
                    LoggerProxy.DLog(tag: kLogTag, msg: "有其他chunk下载失败，直接取消下载任务")
                    return
                }

                buffer.append(byte)
                if buffer.count >= 8 * 1024 {
                    try writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
                    downloadedBytes += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }

                if state == .paused {
                    let cancelSubject = PassthroughSubject<Void, Never>()
                    var events = [AnyCancellable]()
                    let subject = downloadTask.stateSubject.filter({
                        $0 != .paused
                    }).map({ _ in () }).merge(with: cancelSubject)

                    // 处理暂停状态
                    while state == .paused { // 直接调用，不需要 await
                        if !buffer.isEmpty {
                            try writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
                            downloadedBytes += Int64(buffer.count)
                            buffer.removeAll(keepingCapacity: true)
                        }

                        await withTaskCancellationHandler {
                            for await _ in subject.values {
                                break
                            }
                        } onCancel: {
                            cancelSubject.send(())
                        }

                        if state == .cancelled { // 直接调用，不需要 await
                            throw ChunkDownloadError.cancelled
                        }
                        try Task.checkCancellation()
                    }
                }
            }

            // 写入剩余缓冲区数据
            if !buffer.isEmpty {
                try writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
                downloadedBytes += Int64(buffer.count)
                buffer.removeAll()
            }

            // 验证下载的字节数
            let expectedBytes = chunk.totalChunkSize
            if downloadedBytes != expectedBytes {
                LoggerProxy.DLog(tag: kLogTag, msg: "验证下载结果失败:\(downloadedBytes)!=\(expectedBytes) , \(request.allHTTPHeaderFields),response=>\(response)")
                throw ChunkDownloadError.corruptedChunk(chunk.identifier)
            }

            LoggerProxy.DLog(tag: kLogTag, msg: "close file handler:\(identifier)")

            // 更新分片状态并处理完成
//            private func updateChunkStatus(at index: Int, completed: Bool, downloadedBytes: Int64) {
            updateChunkStatus(at: chunk.index, completed: true, downloadedBytes: downloadedBytes) // 直接调用，不需要 await
            await onChunkComplete(for: chunk)
        } catch {
            await handleChunkError(error, for: chunk)
        }
    }

    private func onChunkComplete(for chunk: ChunkTask) async {
        let allCompleted = markChunkComplete(for: chunk.identifier) // 直接调用，不需要 await

        let state = self.state
        guard state == .downloading || state == .preparing else { return }

        if allCompleted {
            await mergeChunks()
        } else {
            checkAndStartAvailableChunksDownload()
        }
    }

    private func mergeChunks() async {
        do {
            try await mergeChunksToFile()
            cleanup() // 直接调用，不需要 await
            await handleDownloadCompletion()
        } catch {
            let chunkError: ChunkDownloadError
            if let ce = error as? ChunkDownloadError {
                chunkError = ce
            } else {
                chunkError = .unknown(error)
            }
            await handleDownloadFailure(error: chunkError)
        }
    }

    private func mergeChunksToFile() async throws {
        update(state: .merging) // 直接调用，不需要 await

        guard let tempMergeFile = tempDirectory?.appendingPathComponent("final_merged_file.tmp") else {
            throw ChunkDownloadError.fileSystemError("无法确定合并文件的临时路径")
        }
        /// 删除
        if FileManager.default.fileExists(atPath: tempMergeFile.path) {
            try FileManager.default.removeItem(at: tempMergeFile)
        }

        try checkDiskSpace(requiredSpace: totalBytes, destinationURL: downloadTask.destinationURL)

        // 校验分块文件大小是否都是预期的
        for chunkTask in chunkTasks {
            try validateChunk(chunkTask)
        }

        // 创建合并文件
        FileManager.default.createFile(atPath: tempMergeFile.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempMergeFile)
        defer { try? fileHandle.close() }

        /// 按照开始顺序，写入
        for chunkTask in chunkTasks.sorted(by: { $0.start < $1.start }) {
            let chunkHandle = try FileHandle(forReadingFrom: chunkTask.filePath)
            defer { try? chunkHandle.close() }

            // 使用 128k 块，进行文件合并
            let bufferSize = 128 * 1024
            while let data = try chunkHandle.read(upToCount: bufferSize) {
                try fileHandle.write(contentsOf: data)
            }
        }

        let destinationDirectory = downloadTask.destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        // 如果目标文件存在，删除并重命名
        LoggerProxy.DLog(tag: kLogTag, msg: "merge move from:\(tempMergeFile) to:\(downloadTask.destinationURL)")
        if FileManager.default.fileExists(atPath: downloadTask.destinationURL.path) {
            try FileManager.default.removeItem(at: downloadTask.destinationURL)
        }
        try FileManager.default.moveItem(at: tempMergeFile, to: downloadTask.destinationURL)
    }

    private func checkDiskSpace(requiredSpace: Int64, destinationURL: URL) throws {
        if DiskSpaceManager.shared.getAvailableDiskSpace(for: destinationURL.path) < requiredSpace {
            throw ChunkDownloadError.insufficientDiskSpace
        }
    }

    private func validateChunk(_ chunk: ChunkTask) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: chunk.filePath.path) else {
            throw ChunkDownloadError.corruptedChunk(chunk.identifier)
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: chunk.filePath.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            if fileSize != chunk.totalChunkSize {
                throw ChunkDownloadError.corruptedChunk(chunk.identifier)
            }
        } catch {
            throw ChunkDownloadError.corruptedChunk(chunk.identifier)
        }
    }

    private func handleDownloadCompletion() async {
        let fullSize: Int64
        if totalBytes > 0 {
            fullSize = totalBytes
        } else {
            fullSize = taskDownloadedBytes.values.reduce(0, +)
        }
        update(progress: (fullSize, fullSize))
        update(state: .completed) // 直接调用，不需要 await
    }

    private func handleDownloadFailure(error: ChunkDownloadError) async {
        LoggerProxy.ELog(tag: kLogTag, msg: "handleDownloadFailure:\(error)")
        let currentState = state // 直接调用，不需要 await
        /// 已经报告了失败，不重复报
        if currentState.isFailed {
            return
        }
        if currentState != .completed && currentState != .cancelled {
            update(state: .failed(.chunkDownloadError(error))) // 直接调用，不需要 await
        }
        /// 异常了，取消所有其他下载
        cancelAllDownloadTasks()
    }

    private func handleChunkError(_ error: Error, for chunk: ChunkTask, funcName: StaticString = #function, line: Int = #line) async {
        LoggerProxy.ELog(tag: kLogTag, msg: "handler chunk error:\(error)", funcName: funcName, line: line)
        let chunkError: ChunkDownloadError
        if let ce = error as? ChunkDownloadError {
            chunkError = ce
        } else {
            chunkError = .unknown(error)
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
    }
}
