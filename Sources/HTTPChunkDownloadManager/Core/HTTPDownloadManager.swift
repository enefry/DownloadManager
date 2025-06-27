import Combine
import ConcurrencyCollection
import CryptoKit
import DownloadManagerBasic
import Foundation
import LoggerProxy

fileprivate let kLogTag = "HTTPChunkDownloadManager"

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

    /// 分块任务
    private struct Chunk: Sendable {
        let identifier: String
        let index: Int
        let downloadTask: any HTTPChunkDownloadTaskProtocol
        let start: Int64
        let end: Int64
        var downloadedBytes: Int64
        var filePath: URL
        var isCompleted: Bool

        var totalChunkSize: Int64 {
            end - start + 1
        }
    }

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
    private func updateDownloadProgress(for identifier: String, addedBytes: Int64) async -> (Int64, Int64) {
        let result: (Int64, Int64)
        if let currentBytes = taskDownloadedBytes[identifier] {
            let newBytes = currentBytes + addedBytes
            taskDownloadedBytes[identifier] = newBytes
            result = (currentBytes, newBytes)
        } else {
            taskDownloadedBytes[identifier] = addedBytes
            result = (0, addedBytes)
        }
        await updateProgressIfNeeded()
        return result
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
            let task = Task {
                await self.downloadNormalAsync(request: request)
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

    /// 普通下载，就是一次性下载全部
    private func downloadNormalAsync(request: URLRequest) async {
        LoggerProxy.DLog(tag: kLogTag, msg: "start downloadNormalAsync")
        let identifier = downloadTask.identifier
        let tempFile = downloadTask.destinationURL.appendingPathExtension(".downloading")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw DownloadError.invalidResponse
            }

            let contentLength = httpResponse.allHeaderFields["Content-Length"] as? String
            let expectedTotalBytes = contentLength.flatMap { Int64($0) } ?? -1
            await updateTotalBytes(expectedTotalBytes) // 直接调用，不需要 await

            let destinationDirectory = downloadTask.destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: downloadTask.destinationURL)
            FileManager.default.createFile(atPath: downloadTask.destinationURL.path, contents: nil)

            let fileHandle = try FileHandle(forWritingTo: tempFile)
            defer {
                try? fileHandle.close()
            }
            var totalDownloaded: Int64 = 0
            var buffer = Data()

            for try await byte in bytes {
                try Task.checkCancellation()

                if state == .cancelled {
                    throw DownloadError.cancelled
                }

                buffer.append(byte)

                if buffer.count >= configuration.bufferSize {
                    try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
                    totalDownloaded += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }

                if state == .paused {
                    if !buffer.isEmpty {
                        try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
                        totalDownloaded += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)
                    }
                    try await waitForResumeOrCancel()
                }
            }

            if !buffer.isEmpty {
                try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
                totalDownloaded += Int64(buffer.count)
                buffer.removeAll()
            }

            LoggerProxy.DLog(tag: kLogTag, msg: "close file handler for normal download")

            if expectedTotalBytes > 0, /// 已经有文件长度的前提
               totalDownloaded != expectedTotalBytes {
                throw DownloadError.corruptedChunk(identifier)
            }
            // 下载完成才重命名回去
            try FileManager.default.moveItem(at: tempFile, to: downloadTask.destinationURL)
            await handleDownloadCompletion()
        } catch {
            if FileManager.default.fileExists(atPath: tempFile.path) {
                try? FileManager.default.removeItem(at: tempFile)
            }
            await handleNormalDownloadError(error)
        }
    }

    private func writeBufferToFile(buffer: Data, fileHandle: FileHandle, identifier: String) async throws {
        let deltaSize = Int64(buffer.count)
        try fileHandle.write(contentsOf: buffer)
        let progress = await updateDownloadProgress(for: identifier, addedBytes: deltaSize)
        LoggerProxy.VLog(tag: kLogTag, msg: "write to file handler for download with: offset=\(progress.0) +  \(deltaSize)=\(progress.1) \(identifier)")
    }

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
            let request = try await downloadTask.buildRequest(headers: ["Range": "bytes=\(startByte)-\(endByte)"])

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
    private func downloadChunkAsync(request: URLRequest, chunk: Chunk) async {
        LoggerProxy.DLog(tag: kLogTag, msg: "start downloadChunkAsync--->:\(chunk.identifier)")
//        var taskFileHandle: FileHandle?
        var downloadedBytes: Int64 = chunk.downloadedBytes
        let identifier = chunk.identifier
        do {
            if await state == .cancelled {
                return
            }
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 206 || httpResponse.statusCode == 200 else {
                throw DownloadError.invalidResponse
            }

            let fileHandle = try await openFileHandler(for: chunk)
            defer {
                try? fileHandle.close()
            }

            // 初始化任务下载字节数
//            await updateDownloadProgress(for: identifier, addedBytes: chunk.downloadedBytes) // 直接调用，不需要 await

            var buffer = Data()
            for try await byte in bytes {
                try Task.checkCancellation()

                if await state == .cancelled {
                    throw DownloadError.cancelled
                }
                /// 其他下载失败
                if await state.isFailed {
                    // 直接不玩了……
                    LoggerProxy.DLog(tag: kLogTag, msg: "有其他chunk下载失败，直接取消下载任务")
                    return
                }

                buffer.append(byte)
                if await state == .paused {
                    if !buffer.isEmpty {
                        try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
                        downloadedBytes += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)
                    }

                    try await waitForResumeOrCancel()
                }
                if buffer.count >= configuration.bufferSize { // 64k 一次保存
                    try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
                    downloadedBytes += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }
            }

            // 写入剩余缓冲区数据
            if !buffer.isEmpty {
                try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, identifier: identifier)
                downloadedBytes += Int64(buffer.count)
                buffer.removeAll()
            }

            // 验证下载的字节数
            let expectedBytes = chunk.totalChunkSize
            if downloadedBytes != expectedBytes {
                LoggerProxy.DLog(tag: kLogTag, msg: "验证下载结果失败:\(downloadedBytes)!=\(expectedBytes) , \(request.allHTTPHeaderFields),response=>\(response)")
                throw DownloadError.corruptedChunk(chunk.identifier)
            }

            LoggerProxy.DLog(tag: kLogTag, msg: "close file handler:\(identifier)")

            // 更新分片状态并处理完成
            await updateChunkStatus(at: chunk.index, completed: true, downloadedBytes: downloadedBytes) // 直接调用，不需要 await
            await onChunkComplete(for: chunk)
        } catch {
            await handleChunkError(error, for: chunk)
        }
    }

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

        // 创建合并文件
        FileManager.default.createFile(atPath: tempMergeFile.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempMergeFile)
        defer { try? fileHandle.close() }

        /// 按照开始顺序，写入
        for chunkTask in chunkTasks.sorted(by: { $0.start < $1.start }) {
            let chunkHandle = try FileHandle(forReadingFrom: chunkTask.filePath)
            defer { try? chunkHandle.close() }

            // 使用 128k 块，进行文件合并
            let bufferSize = Int(min(max(configuration.chunkSize, 128 * 1024), 1 * 1024 * 1024)) // 128k ~ 1m
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
