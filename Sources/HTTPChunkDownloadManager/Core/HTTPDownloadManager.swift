import Combine
import ConcurrencyCollection
import CryptoKit
import Darwin.C
import DownloadManagerBasic
import Foundation
import LoggerProxy

fileprivate let kLogTag = "DM.HD"

/// 合并后的下载管理器 Actor
public actor HTTPDownloadManager: HTTPChunkDownloadManagerProtocol { /// nonisolated
    private struct ChunkProgress: Sendable, Equatable {
        var downloadedBytes: Int64
        var isCompleted: Bool
    }

    private final class ChunkProgressFile: @unchecked Sendable {
        private static let magic: UInt32 = 0x5044_4348 // HCDP
        private static let version: UInt16 = 1
        private static let headerSize = 128
        private static let slotSize = 64
        private static let slotsPerChunk = 2
        private static let completedFlag: UInt32 = 1

        private let fileURL: URL
        private let totalBytes: Int64
        private let chunkSize: Int64
        private let chunkCount: Int
        private let identifierHash: UInt64
        private var fd: Int32 = -1

        init(fileURL: URL, totalBytes: Int64, chunkSize: Int64, chunkCount: Int, identifierHash: UInt64) throws {
            self.fileURL = fileURL
            self.totalBytes = totalBytes
            self.chunkSize = chunkSize
            self.chunkCount = chunkCount
            self.identifierHash = identifierHash

            let directory = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            fd = open(fileURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
            if fd == -1 {
                throw Self.fileIOError("无法打开进度文件:\(fileURL.path)")
            }

            if try !hasValidHeader() {
                try initializeFile()
            }
        }

        deinit {
            close()
        }

        func close() {
            if fd != -1 {
                Darwin.close(fd)
                fd = -1
            }
        }

        func readProgress(index: Int, chunkLength: Int64) throws -> ChunkProgress {
            let slotA = try readSlot(index: index, slot: 0, chunkLength: chunkLength)
            let slotB = try readSlot(index: index, slot: 1, chunkLength: chunkLength)

            switch (slotA, slotB) {
            case let (.some(a), .some(b)):
                return a.generation >= b.generation ? a.progress : b.progress
            case let (.some(a), .none):
                return a.progress
            case let (.none, .some(b)):
                return b.progress
            case (.none, .none):
                return ChunkProgress(downloadedBytes: 0, isCompleted: false)
            }
        }

        func writeProgress(index: Int, downloadedBytes: Int64, isCompleted: Bool, chunkLength: Int64) throws {
            let slotA = try readSlot(index: index, slot: 0, chunkLength: chunkLength)
            let slotB = try readSlot(index: index, slot: 1, chunkLength: chunkLength)
            let currentSlot: Slot?
            switch (slotA, slotB) {
            case let (.some(a), .some(b)):
                currentSlot = a.generation >= b.generation ? a : b
            case let (.some(a), .none):
                currentSlot = a
            case let (.none, .some(b)):
                currentSlot = b
            case (.none, .none):
                currentSlot = nil
            }

            if currentSlot?.progress.isCompleted == true {
                return
            }

            let currentBytes = currentSlot?.progress.downloadedBytes ?? 0
            let clampedBytes = min(max(max(downloadedBytes, currentBytes), 0), chunkLength)
            let completed = isCompleted && clampedBytes == chunkLength
            let generation = max(slotA?.generation ?? 0, slotB?.generation ?? 0) + 1
            let targetSlot: Int

            if let a = slotA, let b = slotB {
                targetSlot = a.generation <= b.generation ? 0 : 1
            } else if slotA == nil {
                targetSlot = 0
            } else {
                targetSlot = 1
            }

            let flags = completed ? Self.completedFlag : 0
            var data = Data()
            data.reserveCapacity(Self.slotSize)
            Self.appendUInt64(generation, to: &data)
            Self.appendInt64(clampedBytes, to: &data)
            Self.appendUInt64(~UInt64(bitPattern: clampedBytes), to: &data)
            Self.appendUInt32(flags, to: &data)
            Self.appendUInt32(~flags, to: &data)
            Self.pad(&data, to: Self.slotSize)

            try Self.writeAll(fd: fd, data: data, offset: slotOffset(index: index, slot: targetSlot))
        }

        private struct Slot {
            var generation: UInt64
            var progress: ChunkProgress
        }

        private func hasValidHeader() throws -> Bool {
            let data = try Self.readUpTo(fd: fd, count: Self.headerSize, offset: 0)
            guard data.count == Self.headerSize else { return false }

            return Self.readUInt32(data, 0) == Self.magic
                && Self.readUInt16(data, 4) == Self.version
                && Int(Self.readUInt16(data, 6)) == Self.headerSize
                && Int(Self.readUInt16(data, 8)) == Self.slotSize
                && Int(Self.readUInt16(data, 10)) == Self.slotsPerChunk
                && Int(Self.readUInt32(data, 12)) == chunkCount
                && Self.readInt64(data, 24) == totalBytes
                && Self.readInt64(data, 32) == chunkSize
                && Self.readUInt64(data, 40) == identifierHash
        }

        private func initializeFile() throws {
            let fileSize = Self.headerSize + chunkCount * Self.slotsPerChunk * Self.slotSize
            if ftruncate(fd, 0) == -1 {
                throw Self.fileIOError("重置进度文件失败:\(fileURL.path)")
            }
            if ftruncate(fd, off_t(fileSize)) == -1 {
                throw Self.fileIOError("初始化进度文件大小失败:\(fileURL.path)")
            }

            var header = Data()
            header.reserveCapacity(Self.headerSize)
            Self.appendUInt32(Self.magic, to: &header)
            Self.appendUInt16(Self.version, to: &header)
            Self.appendUInt16(UInt16(Self.headerSize), to: &header)
            Self.appendUInt16(UInt16(Self.slotSize), to: &header)
            Self.appendUInt16(UInt16(Self.slotsPerChunk), to: &header)
            Self.appendUInt32(UInt32(chunkCount), to: &header)
            Self.appendUInt32(0, to: &header)
            Self.appendUInt32(0, to: &header)
            Self.appendInt64(totalBytes, to: &header)
            Self.appendInt64(chunkSize, to: &header)
            Self.appendUInt64(identifierHash, to: &header)
            Self.pad(&header, to: Self.headerSize)
            try Self.writeAll(fd: fd, data: header, offset: 0)
        }

        private func readSlot(index: Int, slot: Int, chunkLength: Int64) throws -> Slot? {
            let data = try Self.readUpTo(fd: fd, count: Self.slotSize, offset: slotOffset(index: index, slot: slot))
            guard data.count == Self.slotSize else { return nil }

            let generation = Self.readUInt64(data, 0)
            let downloadedBytes = Self.readInt64(data, 8)
            let invertedBytes = Self.readUInt64(data, 16)
            let flags = Self.readUInt32(data, 24)
            let invertedFlags = Self.readUInt32(data, 28)

            guard generation > 0 else { return nil }
            guard invertedBytes == ~UInt64(bitPattern: downloadedBytes) else { return nil }
            guard invertedFlags == ~flags else { return nil }
            guard downloadedBytes >= 0, downloadedBytes <= chunkLength else { return nil }

            let isCompleted = (flags & Self.completedFlag) != 0
            guard !isCompleted || downloadedBytes == chunkLength else { return nil }

            return Slot(generation: generation, progress: ChunkProgress(downloadedBytes: downloadedBytes, isCompleted: isCompleted))
        }

        private func slotOffset(index: Int, slot: Int) -> Int64 {
            Int64(Self.headerSize + (index * Self.slotsPerChunk + slot) * Self.slotSize)
        }

        private static func appendUInt16(_ value: UInt16, to data: inout Data) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        private static func appendUInt32(_ value: UInt32, to data: inout Data) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        private static func appendUInt64(_ value: UInt64, to data: inout Data) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        private static func appendInt64(_ value: Int64, to data: inout Data) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        private static func pad(_ data: inout Data, to size: Int) {
            if data.count < size {
                data.append(contentsOf: repeatElement(UInt8(0), count: size - data.count))
            }
        }

        private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
            data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
        }

        private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
            data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }

        private static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
            data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
        }

        private static func readInt64(_ data: Data, _ offset: Int) -> Int64 {
            data.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int64.self)) }
        }

        private static func readUpTo(fd: Int32, count: Int, offset: Int64) throws -> Data {
            var data = Data(count: count)
            var totalRead = 0
            try data.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                while totalRead < count {
                    let bytesRead = pread(fd, baseAddress.advanced(by: totalRead), count - totalRead, off_t(offset + Int64(totalRead)))
                    if bytesRead == 0 {
                        break
                    } else if bytesRead == -1 {
                        if errno == EINTR {
                            continue
                        }
                        throw fileIOError("读取进度文件失败")
                    }
                    totalRead += bytesRead
                }
            }
            data.removeSubrange(totalRead ..< data.count)
            return data
        }

        private static func writeAll(fd: Int32, data: Data, offset: Int64) throws {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var totalWritten = 0
                while totalWritten < rawBuffer.count {
                    let bytesWritten = pwrite(fd, baseAddress.advanced(by: totalWritten), rawBuffer.count - totalWritten, off_t(offset + Int64(totalWritten)))
                    if bytesWritten == -1 {
                        if errno == EINTR {
                            continue
                        }
                        throw fileIOError("写入进度文件失败")
                    }
                    if bytesWritten == 0 {
                        throw fileIOError("写入进度文件失败: partial write")
                    }
                    totalWritten += bytesWritten
                }
            }
        }

        private static func fileIOError(_ message: String) -> DownloadError {
            DownloadError.fileIOError("\(message), errno:\(errno), \(String(cString: strerror(errno)))")
        }
    }

    /// 分块任务 - 基于 DataTask 的可控下载方案
    private final class Chunk: NSObject, @unchecked Sendable, URLSessionDataDelegate {
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

        private var fileDescriptor: Int32 = -1

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
            closeFile()
        }

        // MARK: - 文件操作

        private func prepareFileForWriting() throws {
            let targetDirectory = filePath.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: targetDirectory.path) {
                try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            }

            // 如果文件不存在，创建空文件
            if !FileManager.default.fileExists(atPath: filePath.path) {
                _ = FileManager.default.createFile(atPath: filePath.path, contents: nil)
            }

            fileDescriptor = open(filePath.path, O_WRONLY)
            if fileDescriptor == -1 {
                throw DownloadError.fileIOError("无法打开目标文件:\(filePath.path), errno:\(errno), \(String(cString: strerror(errno)))")
            }
        }

        private func writeDataToFile(_ data: Data) throws {
            guard fileDescriptor != -1 else {
                throw DownloadError.fileIOError("File descriptor not available for \(identifier)")
            }

            if totalChunkSize > 0, downloadedBytes + Int64(data.count) > totalChunkSize {
                throw DownloadError.corruptedChunk("Chunk \(identifier) received more bytes than expected")
            }

            let absoluteOffset = max(0, start) + downloadedBytes
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var totalWritten = 0
                while totalWritten < rawBuffer.count {
                    let bytesWritten = pwrite(
                        fileDescriptor,
                        baseAddress.advanced(by: totalWritten),
                        rawBuffer.count - totalWritten,
                        off_t(absoluteOffset + Int64(totalWritten))
                    )
                    if bytesWritten == -1 {
                        if errno == EINTR {
                            continue
                        }
                        throw DownloadError.fileIOError("写入目标文件失败:\(identifier), errno:\(errno), \(String(cString: strerror(errno)))")
                    }
                    if bytesWritten == 0 {
                        throw DownloadError.fileIOError("写入目标文件失败:\(identifier), partial write")
                    }
                    totalWritten += bytesWritten
                }
            }
            bytesWritten += Int64(data.count)
            downloadedBytes += Int64(data.count)
        }

        private func closeFile() {
            if fileDescriptor != -1 {
                Darwin.close(fileDescriptor)
                fileDescriptor = -1
            }
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
                closeFile()
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
            closeFile()
            sendCompletion(.failure(CancellationError()))
            LoggerProxy.DLog(tag: kLogTag, msg: "Chunk \(identifier) cancelled")
        }

        /// 重置分块（清除已下载数据，重新开始）
        func resetChunk() throws {
            cancelDownload()
            downloadedBytes = 0
            bytesWritten = 0
            isCompleted = false

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

    /// 固定格式进度文件，用于记录每个分片的断点位置
    private var progressFilePath: URL
    private var progressFile: ChunkProgressFile?
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
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTTPChunkDownloadManager")
            .appendingPathComponent("\(downloadTask.identifier).downloading")
        progressFilePath = tempDirectory.appendingPathComponent("progress.dat")
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
            closeProgressFile()
            if FileManager.default.fileExists(atPath: tempDirectory.path) {
                try FileManager.default.removeItem(at: tempDirectory)
            }
        } catch {
            LoggerProxy.DLog(tag: kLogTag, msg: "Error cleaning up temporary directory: \(error.localizedDescription)")
        }
    }

    private func closeProgressFile() {
        progressFile?.close()
        progressFile = nil
    }

    /// 创建临时文件夹
    private func createTempDirectory() throws {
        if !FileManager.default.fileExists(atPath: tempDirectory.path) {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        }
        LoggerProxy.DLog(tag: kLogTag, msg: "createTempDirectory:\(tempDirectory)")
    }

    /// 创建目标稀疏文件。APFS/HFS+ 上 ftruncate 扩展文件不会为未写入区间分配真实数据块。
    private func prepareSparseDestinationFile() throws {
        let destinationDirectory = downloadTask.destinationURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: destinationDirectory.path) {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        }

        if !FileManager.default.fileExists(atPath: downloadTask.destinationURL.path) {
            _ = FileManager.default.createFile(atPath: downloadTask.destinationURL.path, contents: nil)
        }

        let fileHandle = try FileHandle(forWritingTo: downloadTask.destinationURL)
        defer { try? fileHandle.close() }
        try fileHandle.truncate(atOffset: UInt64(totalBytes))
    }

    private func prepareProgressFile() throws {
        closeProgressFile()
        progressFile = try ChunkProgressFile(
            fileURL: progressFilePath,
            totalBytes: totalBytes,
            chunkSize: configuration.chunkSize,
            chunkCount: chunkTasks.count,
            identifierHash: progressIdentifierHash()
        )
    }

    private func progressIdentifierHash() -> UInt64 {
        let key = "\(downloadTask.url.absoluteString)\n\(downloadTask.destinationURL.absoluteString)\n\(downloadTask.identifier)"
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
        }
    }

    /// 创建分块任务
    private func createChunkTasks() {
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
                filePath: downloadTask.destinationURL,
                isCompleted: false
            )
            tempChunkTasks.append(chunkTask)
            offset += chunkSize
            index += 1
        }

        chunkTasks = tempChunkTasks
    }

    /// 检查本地分块
    private func checkLocalChunksStatus() async {
        var totalDownloaded: Int64 = 0
        let destinationExists = FileManager.default.fileExists(atPath: downloadTask.destinationURL.path)

        for i in 0 ..< chunkTasks.count {
            let chunkTask = chunkTasks[i]
            if destinationExists,
               let progressFile = progressFile,
               let progress = try? progressFile.readProgress(index: chunkTask.index, chunkLength: chunkTask.totalChunkSize) {
                chunkTasks[i].downloadedBytes = progress.downloadedBytes
                chunkTasks[i].isCompleted = progress.isCompleted
                taskDownloadedBytes[chunkTask.identifier] = progress.downloadedBytes
            } else {
                chunkTasks[i].downloadedBytes = 0
                chunkTasks[i].isCompleted = false
                taskDownloadedBytes[chunkTask.identifier] = 0
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
    private func updateDownloadProgress(for chunk: Chunk, bytes: Int64) async {
        guard chunkTasks.indices.contains(chunk.index) else { return }
        let currentChunk = chunkTasks[chunk.index]
        guard !currentChunk.isCompleted else { return }

        let currentBytes = taskDownloadedBytes[chunk.identifier] ?? currentChunk.downloadedBytes
        let nextBytes = max(currentBytes, bytes)
        taskDownloadedBytes[chunk.identifier] = nextBytes
        writeProgress(for: chunk.index, downloadedBytes: nextBytes, isCompleted: false)
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
        taskDownloadedBytes[chunkTasks[index].identifier] = downloadedBytes
        writeProgress(for: index, downloadedBytes: downloadedBytes, isCompleted: completed)
    }

    private func writeProgress(for index: Int, downloadedBytes: Int64, isCompleted: Bool) {
        guard chunkTasks.indices.contains(index), let progressFile = progressFile else { return }
        let chunk = chunkTasks[index]
        do {
            try progressFile.writeProgress(
                index: index,
                downloadedBytes: downloadedBytes,
                isCompleted: isCompleted,
                chunkLength: chunk.totalChunkSize
            )
        } catch {
            LoggerProxy.WLog(tag: kLogTag, msg: "写入分片进度失败: \(error)")
        }
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

            let (_, response) = try await URLSession.shared.data(for: downloadTask.buildRequest(method: "HEAD"))
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
            let (_, response) = try await URLSession.shared.data(for: downloadTask.buildRequest(headers: ["Range": "bytes=0-1"]))
            await handleServerSupportResponse(response: response, error: nil, isHeadRequest: false)
        } catch {
            await handleServerSupportResponse(response: nil, error: error, isHeadRequest: false)
        }
    }

    /// 获取到文件长度后到操作
    private func handleServerSupportResponse(response: URLResponse?, error: Error?, isHeadRequest: Bool) async {
        LoggerProxy.DLog(tag: kLogTag, msg: "\(Date()):handleServerSupportResponse:\(downloadTask.identifier), resp=\(String(describing: response)),error=\(String(describing: error))")

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
            try prepareSparseDestinationFile()
            createChunkTasks()
            try prepareProgressFile()
            await checkLocalChunksStatus()
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
        let taskKey = downloadTask.identifier
        /// 普通下载就是一次性的chunk
        let fullChunk = Chunk(identifier: downloadTask.identifier, index: 0, downloadTask: downloadTask, start: 0, end: -1, downloadedBytes: 0, filePath: downloadTask.destinationURL, isCompleted: false)
        let task = Task {
            await downloadChunk(fullChunk)
            self.activeTasks[taskKey] = nil
        }
        activeTasks[taskKey] = task
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
                await finishChunkDownload()
            }
        } else {
            for chunk in chunksToStart {
                await downloadChunk(chunk)
            }
        }
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

    /// 使用 DownloadTask 方式下载分块
    private func downloadChunkAsync(request: URLRequest, chunk: Chunk) async {
        LoggerProxy.DLog(tag: kLogTag, msg: "start downloadChunkWithDownloadTask--->:\(chunk.identifier)")

        do {
            if state == .cancelled {
                return
            }

            // 设置进度回调
            chunk.onProgressUpdate = { [weak self] chunk, downloaded, _ in
                Task {
                    await self?.updateDownloadProgress(for: chunk, bytes: downloaded)
                }
            }
            // 开始下载并等待完成
            _ = try await chunk.startDownload(with: session, request: request)

            let expectedBytes = chunk.totalChunkSize

            if expectedBytes > 0, chunk.downloadedBytes != expectedBytes {
                LoggerProxy.DLog(tag: kLogTag, msg: "验证下载结果失败:\(chunk.downloadedBytes)!=\(expectedBytes) , \(String(describing: request.allHTTPHeaderFields))")
                throw DownloadError.corruptedChunk(chunk.identifier)
            }

            LoggerProxy.DLog(tag: kLogTag, msg: "Chunk download completed: \(chunk.identifier)")

            // 更新分块状态
            updateChunkStatus(at: chunk.index, completed: true, downloadedBytes: chunk.downloadedBytes)
            await onChunkComplete(for: chunk)
        } catch {
            LoggerProxy.DLog(tag: kLogTag, msg: "Chunk download failed: \(chunk.identifier), error: \(error)")
            await handleChunkError(error, for: chunk)
        }
    }

    private func onChunkComplete(for chunk: Chunk) async {
        let allCompleted = markChunkComplete(for: chunk.identifier) // 直接调用，不需要 await

        let state = self.state
        guard state == .downloading || state == .preparing else { return }

        if allCompleted {
            await finishChunkDownload()
        } else {
            await checkAndStartAvailableChunksDownload()
        }
    }

    private func finishChunkDownload() async {
        do {
            try finalizeSparseDestinationFile()
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

    private func finalizeSparseDestinationFile() throws {
        guard FileManager.default.fileExists(atPath: downloadTask.destinationURL.path) else {
            throw DownloadError.fileSystemError("目标文件不存在:\(downloadTask.destinationURL.path)")
        }

        for chunkTask in chunkTasks {
            try validateChunk(chunkTask)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: downloadTask.destinationURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        if totalBytes > 0, fileSize != totalBytes {
            throw DownloadError.fileIOError("目标文件大小错误:\(fileSize), expected:\(totalBytes)")
        }
    }

    private func validateChunk(_ chunk: Chunk) throws {
        if !chunk.isCompleted || chunk.downloadedBytes != chunk.totalChunkSize {
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
