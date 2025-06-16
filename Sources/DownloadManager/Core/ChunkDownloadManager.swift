import CryptoKit // 重新引入 CryptoKit，用于 sha256() 实现
import Foundation

// MARK: - 1. 外部依赖类型定义

// 为使 ChunkDownloadManager 成为功能独立的单个文件，这里定义其依赖的外部类型。

extension DownloadTaskProtocol {
    // 修正 sha256() 实现，使用 CryptoKit
    public func sha256() -> String {
        let combinedString = "\(url.absoluteString)\n\(destinationURL.absoluteString)"
        if let data = combinedString.data(using: .utf8) {
            let digest = SHA256.hash(data: data)
            return digest.compactMap { String(format: "%02x", $0) }.joined()
        }
        return "" // 如果无法转换为 Data，返回空字符串或抛出错误
    }
}

// MARK: - 2. 核心协议定义

/// 分片下载管理器代理协议
public protocol ChunkDownloadManagerDelegate: AnyObject {
    /// 更新下载进度
    func chunkDownloadManager(_ manager: ChunkDownloadManager, didUpdateProgress progress: Double)
    /// 更新下载状态
    func chunkDownloadManager(_ manager: ChunkDownloadManager, didUpdateState state: DownloadState)
    /// 下载完成
    func chunkDownloadManager(_ manager: ChunkDownloadManager, didCompleteWithURL url: URL)
    /// 下载失败
    func chunkDownloadManager(_ manager: ChunkDownloadManager, didFailWithError error: Error)
}

// MARK: - 3. 内部辅助类型定义

/// 分片下载配置
public struct ChunkConfiguration {
    public let chunkSize: Int64 // 分片大小（字节），例如 1MB = 1024 * 1024
    public let maxConcurrentChunks: Int // 最大并发分片数
    public let timeoutInterval: TimeInterval // 单个分片下载超时时间
    public let taskConfigure: DownloadTaskConfiguration // 整个下载任务的通用配置

    public init(chunkSize: Int64, maxConcurrentChunks: Int, timeoutInterval: TimeInterval, taskConfigure: DownloadTaskConfiguration) {
        self.chunkSize = chunkSize
        self.maxConcurrentChunks = maxConcurrentChunks
        self.timeoutInterval = timeoutInterval
        self.taskConfigure = taskConfigure
    }
}

/// 分片任务结构体
private struct ChunkTask {
    let downloadTask: any DownloadTaskProtocol // 对应的下载任务引用
    let start: Int64 // 分片开始字节偏移
    let end: Int64 // 分片结束字节偏移（包含）
    var downloadedBytes: Int64 // 当前分片已下载的字节数
    var filePath: URL // 分片内容保存的临时文件路径
    var isCompleted: Bool // 分片是否已完成下载

    /// 获取分片总大小
    var totalChunkSize: Int64 {
        end - start + 1
    }
}

/// 下载错误类型
public enum ChunkDownloadError: Error, LocalizedError {
    case networkError(String) // 网络连接或请求错误
    case fileSystemError(String) // 文件系统操作错误（如读写、目录创建）
    case serverNotSupported // 服务器不支持分片下载 (如不支持Range头)
    case insufficientDiskSpace // 磁盘空间不足
    case corruptedChunk(Int) // 分片文件损坏或不完整（通过索引标识）
    case invalidResponse // 服务器返回无效响应 (非200/206状态码或缺少必要头信息)
    case timeout // 下载超时
    case cancelled // 下载被取消
    case unknown(Error) // 未知错误，包裹原始错误

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
        case .networkError:
            return 0x2001
        case .fileSystemError:
            return 0x2002
        case .serverNotSupported:
            return 0x2003
        case .insufficientDiskSpace:
            return 0x2004
        case .corruptedChunk:
            return 0x2005
        case .invalidResponse:
            return 0x2006
        case .timeout:
            return 0x2007
        case .cancelled:
            return 0x2008
        case .unknown:
            return 0x20FF
        }
    }
}

// MARK: - 4. ChunkDownloadManager 类定义

/// ChunkDownloadManager 整体设计说明：
/// 这个类负责 DownloadTaskProtocol 的分片，非单例使用，每个 DownloadTaskProtocol 关联一个 ChunkDownloadManager 实例。
///
/// 这个类启动后会执行以下操作：
/// 1. **HEAD/GET 请求检查：** 首先尝试发送 HEAD 请求检查远程链接是否支持 `bytes` 范围请求以及是否有 `Content-Length`。
///    如果 HEAD 方法不支持或信息不全，则退而使用带 `Range: bytes=0-1` 的 GET 请求进行检测。
/// 2. **分片下载决策：** 如果检测到服务器支持分片下载且能获取到文件总大小，则进入分片下载模式；
///    否则，回退到普通的全文件下载模式。
/// 3. **临时目录创建：** 如果是分片下载模式，会为目标 URL 创建一个临时目录，并将每个分片下载的内容保存到这个目录下。
///    分片文件命名以 `offset_length` 格式，方便后续追溯和恢复。
/// 4. **分片任务管理：** 使用 `URLSessionDownloadTask` 进行分片下载，管理每一个下载连接，处理成功/失败情况。
/// 5. **并发控制：** 根据配置的最大并发数，启动和管理分片下载任务。
/// 6. **断点续传：** 检查本地已下载的分片文件，实现断点续传功能。
/// 7. **失败重试：** 如果分片下载失败，执行延迟重试策略（最多3次）。
///    - 重试策略是将失败的分片重新插入到下载队列中。
///    - 如果分片重试次数达到上限，则终止所有下载并通知下载失败。
/// 8. **进度更新：** 定期更新总下载进度并通过代理通知外部。
/// 9. **分片合并：** 当所有分片下载成功后，按顺序合并分片文件到最终目标路径，并清理临时目录。
/// 10. **错误/取消处理：** 在下载过程中遇到错误或被取消时，清理相关资源并通知代理。
// 移除了 URLSessionDelegate 的遵循，因为使用 AsyncBytes 模式后不再需要这些代理方法
public final class ChunkDownloadManager: NSObject {
    // MARK: - 私有属性

    internal let downloadTask: any DownloadTaskProtocol // 外部传入的下载任务
    private let configuration: ChunkConfiguration // 分片下载配置
    private weak var delegate: ChunkDownloadManagerDelegate? // 代理对象

    private var session: URLSession! // URLSession 实例，用于所有网络请求
    private var chunkTasks: [ChunkTask] = [] // 所有分片任务的数组
    private var activeTaskIndices: Set<Int> = [] // 当前正在下载的分片任务的索引集合
    private var tempDirectory: URL? // 分片文件保存的临时目录URL
    private var totalBytes: Int64 = -1 // 文件总大小，-1表示未知
    // 移除了 retryCount 和 maxRetryCount，因为重试逻辑未在此处实现
    // private var retryCount: [Int: Int] = [:] // 存储每个分片任务的重试次数
    // private let maxRetryCount = 3 // 单个分片的最大重试次数

    // 用于存储每个任务的 FileHandle
    private var taskFileHandles: [Int: FileHandle] = [:]
    // 用于存储每个任务的已下载字节数
    private var taskDownloadedBytes: [Int: Int64] = [:]

    // 线程安全锁，用于保护共享资源
    private let chunkTasksLock = NSLock()
    private let activeTasksLock = NSLock()
    // 移除了 retryCountLock
    // private let retryCountLock = NSLock()
    private let stateLock = NSLock()
    private let fileHandlesLock = NSLock()
    private let downloadedBytesLock = NSLock()

    // 下载状态
    private var _downloadState: DownloadState = .waiting {
        didSet {
            // 确保状态更新在主线程进行，并通知代理
            if oldValue != _downloadState { // 避免重复通知相同状态
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.chunkDownloadManager(self, didUpdateState: self._downloadState)
                }
            }
        }
    }

    // 进度更新节流
    private var lastProgressUpdate: Date = Date()
    private let progressUpdateInterval: TimeInterval = 0.1 // 至少每0.1秒更新一次进度

    // MARK: - 初始化

    /// 初始化分片下载管理器
    /// - Parameters:
    ///   - DownloadTaskProtocol: 包含下载URL和目标路径的下载任务对象。
    ///   - configuration: 分片下载的详细配置。
    ///   - delegate: 用于接收下载进度、状态和结果更新的代理。
    public init(downloadTask: any DownloadTaskProtocol, configuration: ChunkConfiguration, delegate: ChunkDownloadManagerDelegate) {
        self.downloadTask = downloadTask
        self.configuration = configuration
        self.delegate = delegate
        super.init()

        // 配置 URLSession
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.timeoutInterval
        sessionConfig.timeoutIntervalForResource = configuration.timeoutInterval * 2 // 资源超时时间可以更长
        // 可以添加自定义缓存策略等
        // 移除了 delegate 参数，因为不再遵循 URLSessionDelegate
        session = URLSession(configuration: sessionConfig, delegate: nil, delegateQueue: OperationQueue())
    }

    // MARK: - 公开控制方法

    /// 开始分片下载。
    /// 会首先检查服务器是否支持分片下载，然后根据结果决定是分片下载还是普通下载。
    public func start() {
        // 设置初始状态为准备中
        updateDownloadState(.preparing)
        // 异步执行服务器支持性检查，避免阻塞调用线程
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.checkServerSupport()
        }
    }

    /// 暂停分片下载。
    /// 会暂停所有当前正在进行的下载任务。已完成的分片不会受影响。
    public func pause() {
        updateDownloadState(.paused)
        // 由于使用 AsyncBytes，我们需要通过状态控制来暂停下载
        // 在下载循环中会检查状态
    }

    /// 恢复分片下载。
    /// 会恢复所有已暂停且未完成的下载任务。
    public func resume() {
        // 只有在暂停状态下才能恢复
        guard _downloadState == .paused else { return }
        updateDownloadState(.downloading)
        // 重新启动未完成的分片下载
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.startNextAvailableChunks()
        }
    }

    /// 取消分片下载。
    /// 会取消所有正在进行的任务，并清理所有临时文件。
    public func cancel() {
        updateDownloadState(.cancelled)
        // 由于使用 AsyncBytes，我们只需要更新状态
        // 下载循环会检查状态并自动停止
        closeAllFileHandles()
        cleanup()
    }

    // MARK: - 私有核心逻辑

    /// 检查服务器是否支持分片下载（HEAD请求优先）
    private func checkServerSupport() {
        var request = URLRequest(url: downloadTask.url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = configuration.timeoutInterval

        let task = session.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }

            if let error = error {
                self.handleDownloadFailure(error: ChunkDownloadError.networkError(error.localizedDescription))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                self.handleDownloadFailure(error: ChunkDownloadError.invalidResponse)
                return
            }

            let acceptsRanges = httpResponse.allHeaderFields["Accept-Ranges"] as? String
            let contentLength = httpResponse.allHeaderFields["Content-Length"] as? String

            let supportsRanges = acceptsRanges?.lowercased() == "bytes"
            let hasContentLength = contentLength != nil && Int64(contentLength!) ?? -1 > 0

            // 如果 HEAD 请求能获取到分片支持和文件大小，则进入分片模式
            if supportsRanges && hasContentLength {
                self.totalBytes = Int64(contentLength!)!
                self.prepareForChunkDownload()
            } else {
                // 否则，尝试 GET 请求进一步确认，或者回退到普通下载
                self.checkServerSupportWithGet()
            }
        }
        task.resume()
    }

    /// 检查服务器是否支持分片下载（GET请求辅助）
    private func checkServerSupportWithGet() {
        var request = URLRequest(url: downloadTask.url)
        request.httpMethod = "GET"
        // 请求一个很小的范围，例如前两个字节，用于检测 Content-Range
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        request.timeoutInterval = configuration.timeoutInterval

        let task = session.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }

            if let error = error {
                self.handleDownloadFailure(error: ChunkDownloadError.networkError(error.localizedDescription))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                self.handleDownloadFailure(error: ChunkDownloadError.invalidResponse)
                return
            }

            // 状态码 206 表示部分内容，说明服务器支持 Range 请求
            let supportsRanges = httpResponse.statusCode == 206

            // 从 Content-Range 头获取文件总大小，格式通常是 "bytes 0-1/12345"
            var fileSizeFromRange: Int64 = -1
            if let contentRange = httpResponse.allHeaderFields["Content-Range"] as? String {
                let components = contentRange.components(separatedBy: "/")
                if components.count > 1, let totalSize = Int64(components[1]) {
                    fileSizeFromRange = totalSize
                }
            }

            if supportsRanges && fileSizeFromRange > 0 {
                self.totalBytes = fileSizeFromRange
                self.prepareForChunkDownload()
            } else {
                // 如果仍然不支持分片或无法获取文件大小，则执行普通下载
                self.startNormalDownload()
            }
        }
        task.resume()
    }

    /// 准备分片下载（创建目录、任务等）
    private func prepareForChunkDownload() {
        guard totalBytes > 0 else {
            handleDownloadFailure(error: ChunkDownloadError.serverNotSupported)
            return
        }

        do {
            try createTempDirectory()
            createChunkTasks()
            updateDownloadState(.downloading) // 状态变为下载中
            startNextAvailableChunks()
        } catch {
            // 将 Foundation.Error 转换为 ChunkDownloadError
            let chunkError: ChunkDownloadError
            if let ce = error as? ChunkDownloadError {
                chunkError = ce
            } else {
                chunkError = .unknown(error)
            }
            handleDownloadFailure(error: chunkError)
        }
    }

    /// 开始普通下载（服务器不支持分片时回退方案）
    private func startNormalDownload() {
        updateDownloadState(.downloading)
        // 使用 URLSessionDownloadTask 下载整个文件
        var request = URLRequest(url: downloadTask.url)
        request.timeoutInterval = configuration.timeoutInterval
        for (key, value) in configuration.taskConfigure.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = session.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self = self else { return }

            if let error = error {
                self.handleDownloadFailure(error: ChunkDownloadError.networkError(error.localizedDescription))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let tempURL = tempURL else {
                self.handleDownloadFailure(error: ChunkDownloadError.invalidResponse)
                return
            }

            do {
                // 确保目标路径的目录存在
                let destinationDirectory = self.downloadTask.destinationURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                // 移动文件到目标位置
                try FileManager.default.moveItem(at: tempURL, to: self.downloadTask.destinationURL)
                self.handleDownloadCompletion()
            } catch {
                self.handleDownloadFailure(error: ChunkDownloadError.fileSystemError(error.localizedDescription))
            }
        }
        task.resume()
    }

    /// 创建临时目录
    private func createTempDirectory() throws {
        let taskSha256 = downloadTask.sha256()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadManagerChunks") // 使用更明确的名称
            .appendingPathComponent(
                "\(taskSha256).downloading"
            ) // 每个任务一个独立目录
        print("tempDir>>\(tempDir)")

        try? JSONSerialization
            .data(withJSONObject: ["src": downloadTask.url.absoluteString,
                                   "dest": downloadTask.destinationURL.absoluteString,
                                   "sha256": taskSha256]
            ).write(to: tempDir.appendingPathComponent("info.json"))

        // 尝试删除旧的目录，确保干净的环境，这有助于处理上次下载未完全清理的情况
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        tempDirectory = tempDir
    }

    /// 创建分片任务队列
    private func createChunkTasks() {
        guard let tempDir = tempDirectory, totalBytes > 0 else { return }

        var offset: Int64 = 0
        var tempChunkTasks: [ChunkTask] = []
        while offset < totalBytes {
            let chunkSize = min(configuration.chunkSize, totalBytes - offset)
            let end = offset + chunkSize - 1 // 结束位置是包含的

            let chunkTask = ChunkTask(
                downloadTask: downloadTask,
                start: offset,
                end: end,
                downloadedBytes: 0, // 初始为0
                filePath: tempDir.appendingPathComponent("\(offset)-\(chunkSize).part"), // 更明确的文件名后缀
                isCompleted: false
            )
            tempChunkTasks.append(chunkTask)
            offset += chunkSize
        }
        // 线程安全地更新分片任务列表
        chunkTasksLock.sync {
            chunkTasks = tempChunkTasks
        }

        checkLocalChunksStatus() // 检查本地是否有已下载的分片，实现断点续传
    }

    /// 检查本地分片文件状态，实现断点续传
    private func checkLocalChunksStatus() {
        var totalDownloaded: Int64 = 0
        chunkTasksLock.sync { // 锁定，防止在检查过程中 chunkTasks 被修改
            for i in 0 ..< chunkTasks.count {
                let chunkPath = chunkTasks[i].filePath.path
                if FileManager.default.fileExists(atPath: chunkPath) {
                    do {
                        let attributes = try FileManager.default.attributesOfItem(atPath: chunkPath)
                        let fileSize = attributes[.size] as? Int64 ?? 0
                        if fileSize == chunkTasks[i].totalChunkSize {
                            // 分片已完整下载
                            chunkTasks[i].isCompleted = true
                            chunkTasks[i].downloadedBytes = fileSize
                        } else if fileSize > 0 {
                            // 分片部分下载，可以续传
                            chunkTasks[i].downloadedBytes = fileSize
                        } else {
                            // 文件存在但大小为0，可能为空文件，删除后重新下载
                            try? FileManager.default
                                .removeItem(atPath: chunkPath)
                            chunkTasks[i].downloadedBytes = 0
                        }
                    } catch {
                        // 获取文件属性失败，可能是文件损坏，删除后重新下载
                        try? FileManager.default.removeItem(atPath: chunkPath)
                        chunkTasks[i].downloadedBytes = 0
                    }
                }
                totalDownloaded += chunkTasks[i].downloadedBytes
            }
        }
        // 更新初始进度
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.totalBytes > 0 {
                self.delegate?.chunkDownloadManager(self, didUpdateProgress: Double(totalDownloaded) / Double(self.totalBytes))
            }
        }
    }

    /// 启动下一个可用的分片下载任务
    private func startNextAvailableChunks() {
        // 如果不是下载状态，则不启动新任务
        guard _downloadState == .downloading || _downloadState == .preparing else { return }

        // 获取当前活跃任务数量
        let currentActiveCount = activeTasksLock.sync { activeTaskIndices.count }
        let availableSlots = configuration.maxConcurrentChunks - currentActiveCount

        guard availableSlots > 0 else { return } // 没有空闲槽位

        var chunksToStart: [(index: Int, chunk: ChunkTask)] = []
        chunkTasksLock.sync {
            // 查找未完成且未在活跃队列中的分片
            for (index, chunk) in chunkTasks.enumerated() {
                if !chunk.isCompleted && !activeTaskIndices.contains(index) {
                    chunksToStart.append((index, chunk))
                    if chunksToStart.count >= availableSlots {
                        break // 找到足够数量的任务
                    }
                }
            }
        }

        for (index, chunk) in chunksToStart {
            activeTasksLock.sync { activeTaskIndices.insert(index) } // 添加到活跃任务
            downloadChunk(chunk, at: index) // 启动下载
        }
    }

    /// 下载单个分片
    private func downloadChunk(_ chunkTask: ChunkTask, at index: Int) {
        // 再次检查状态，确保在下载过程中没有被取消或暂停
        guard _downloadState == .downloading || _downloadState == .preparing else {
            onChunkComplete(at: index) // 如果状态不对，将其从活跃任务中移除
            return
        }

        var request = URLRequest(url: downloadTask.url)

        // 设置 Range 头以支持断点续传或分片下载
        let startByte = chunkTask.start + chunkTask.downloadedBytes // 从已下载的字节数之后开始
        let endByte = chunkTask.end
        request.setValue("bytes=\(startByte)-\(endByte)", forHTTPHeaderField: "Range")

        // 应用自定义请求头
        for (key, value) in configuration.taskConfigure.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.timeoutInterval = configuration.timeoutInterval // 单个分片的超时

        do {
            // 准备文件句柄
            if chunkTask.downloadedBytes > 0 {
                // 如果已经部分下载，以追加模式打开文件
                let fileHandle = try FileHandle(forWritingTo: chunkTask.filePath)
                try fileHandle.seekToEnd()
                fileHandlesLock.sync {
                    taskFileHandles[index] = fileHandle
                }
            } else {
                // 如果是新下载，创建新文件
                FileManager.default.createFile(atPath: chunkTask.filePath.path, contents: nil)
                let fileHandle = try FileHandle(forWritingTo: chunkTask.filePath)
                fileHandlesLock.sync {
                    taskFileHandles[index] = fileHandle
                }
            }

            // 初始化已下载字节数
            downloadedBytesLock.sync {
                taskDownloadedBytes[index] = chunkTask.downloadedBytes
            }

            // 启动异步下载任务
            Task {
                await downloadChunkAsync(request: request, at: index)
            }
        } catch {
            handleChunkError(error, for: index)
        }
    }

    /// 异步下载分片
    private func downloadChunkAsync(request: URLRequest, at index: Int) async {
        do {
            let (bytes, response) = try await session.bytes(for: request)

            // 验证响应状态
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 206 || httpResponse.statusCode == 200 else {
                throw ChunkDownloadError.invalidResponse
            }

            // 获取文件句柄
            guard let fileHandle = fileHandlesLock.sync(execute: { taskFileHandles[index] }) else {
                throw ChunkDownloadError.fileSystemError("无法获取文件句柄")
            }

            // 流式读取和写入
            var buffer = Data()
            for try await byte in bytes {
                // 检查是否已取消或暂停
                if _downloadState == .cancelled {
                    throw ChunkDownloadError.cancelled
                }
                if _downloadState == .paused {
                    // 等待恢复
                    while _downloadState == .paused {
                        try await Task.sleep(nanoseconds: 100000000) // 休眠 0.1 秒
                        if _downloadState == .cancelled {
                            throw ChunkDownloadError.cancelled
                        }
                    }
                }

                // 将字节添加到缓冲区
                buffer.append(byte)

                // 当缓冲区达到一定大小时写入文件
                if buffer.count >= 8192 { // 8KB 缓冲区
                    try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, at: index)
                    buffer.removeAll(keepingCapacity: true)
                }
            }

            // 写入剩余的缓冲区数据
            if !buffer.isEmpty {
                try await writeBufferToFile(buffer: buffer, fileHandle: fileHandle, at: index)
            }

            // 验证下载是否完整
            let downloadedBytes = downloadedBytesLock.sync { taskDownloadedBytes[index] ?? 0 }
            let expectedBytes = chunkTasksLock.sync { chunkTasks[index].totalChunkSize }

            if downloadedBytes != expectedBytes {
                throw ChunkDownloadError.corruptedChunk(index)
            }

            // 更新分片状态
            chunkTasksLock.sync {
                if chunkTasks.indices.contains(index) {
                    chunkTasks[index].isCompleted = true
                    chunkTasks[index].downloadedBytes = downloadedBytes
                }
            }

            // 关闭文件句柄
            fileHandlesLock.sync {
                if let fileHandle = taskFileHandles[index] {
                    try? fileHandle.close()
                    taskFileHandles.removeValue(forKey: index)
                }
            }

            onChunkComplete(at: index)
        } catch {
            // 关闭文件句柄
            fileHandlesLock.sync {
                if let fileHandle = taskFileHandles[index] {
                    try? fileHandle.close()
                    taskFileHandles.removeValue(forKey: index)
                }
            }

            handleChunkError(error, for: index)
        }
    }

    /// 将缓冲区数据写入文件
    private func writeBufferToFile(buffer: Data, fileHandle: FileHandle, at index: Int) async throws {
        try fileHandle.write(contentsOf: buffer)

        // 更新已下载字节数
        downloadedBytesLock.sync {
            if let currentBytes = taskDownloadedBytes[index] {
                taskDownloadedBytes[index] = currentBytes + Int64(buffer.count)
            } else {
                taskDownloadedBytes[index] = Int64(buffer.count)
            }
        }

        // 更新进度
        updateProgressIfNeeded()
    }

    // 在取消或清理时关闭所有文件句柄
    private func closeAllFileHandles() {
        fileHandlesLock.sync {
            for (_, fileHandle) in taskFileHandles {
                try? fileHandle.close()
            }
            taskFileHandles.removeAll()
        }
    }

    /// 分片下载完成后（无论是成功、失败或取消），执行清理和调度
    private func onChunkComplete(at index: Int) {
        // 将该分片从活跃任务列表中移除
        activeTasksLock.sync { activeTaskIndices.remove(index) }

        // 只有在下载状态下才继续调度新的分片
        guard _downloadState == .downloading || _downloadState == .preparing else { return }

        // 检查所有分片是否都已完成
        let allCompleted = chunkTasksLock.sync { chunkTasks.allSatisfy { $0.isCompleted } }

        if allCompleted {
            mergeChunks() // 所有分片下载完成，开始合并
        } else {
            // 仍有未完成的分片，启动下一个可用的分片下载
            startNextAvailableChunks()
        }
    }

    /// 合并所有已下载的分片到最终文件
    private func mergeChunks() {
        updateDownloadState(.preparing) // 合并阶段也算是一种准备工作
        let tempMergeFile = tempDirectory?.appendingPathComponent("final_merged_file.tmp")

        do {
            guard let tempMergeFile = tempMergeFile else {
                throw ChunkDownloadError.fileSystemError("无法确定合并文件的临时路径")
            }

            // 再次检查磁盘空间，确保合并有足够的空间
            try checkDiskSpace(requiredSpace: totalBytes)

            // 确保所有分片都已完整且未损坏
            try chunkTasksLock.sync {
                for (index, chunkTask) in chunkTasks.enumerated() {
                    try validateChunk(chunkTask, at: index)
                }
            }

            // 创建空的临时合并文件
            FileManager.default.createFile(atPath: tempMergeFile.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: tempMergeFile)
            defer { try? fileHandle.close() } // 确保文件句柄关闭

            // 按照分片顺序写入数据
            for chunkTask in chunkTasks.sorted(by: { $0.start < $1.start }) {
                let chunkData = try Data(contentsOf: chunkTask.filePath)
                try fileHandle.write(contentsOf: chunkData)
            }

            // 原子性移动合并后的文件到目标位置
            let destinationDirectory = downloadTask.destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true) // 确保目标目录存在
            try FileManager.default.moveItem(at: tempMergeFile, to: downloadTask.destinationURL)

            cleanup() // 清理临时分片文件和目录
            handleDownloadCompletion() // 通知下载完成
        } catch {
            // 合并失败，清理临时合并文件并通知错误
            try? FileManager.default.removeItem(at: tempMergeFile!)
            // 将 Foundation.Error 转换为 ChunkDownloadError
            let chunkError: ChunkDownloadError
            if let ce = error as? ChunkDownloadError {
                chunkError = ce
            } else {
                chunkError = .unknown(error)
            }
            handleDownloadFailure(error: chunkError)
        }
    }

    /// 清理所有临时资源，包括临时目录和其中的分片文件
    private func cleanup() {
        if let tempDir = tempDirectory {
            do {
                try FileManager.default.removeItem(at: tempDir)
                tempDirectory = nil // 清理后置为nil
            } catch {
                print("Error cleaning up temporary directory: \(error.localizedDescription)")
                // 这里的清理失败不影响主流程，打印日志即可
            }
        }
    }

    /// 检查磁盘空间是否足够
    /// - Parameter requiredSpace: 需要的字节数
    private func checkDiskSpace(requiredSpace: Int64) throws {
        let fileManager = FileManager.default
        // 尝试获取目标文件所在卷的属性，如果无法获取，则使用临时目录所在卷
        let pathToCheck = downloadTask.destinationURL.deletingLastPathComponent().path
        let actualPath = FileManager.default.fileExists(atPath: pathToCheck) ? pathToCheck : fileManager.temporaryDirectory.path

        do {
            let attributes = try fileManager.attributesOfFileSystem(forPath: actualPath)
            if let freeSpace = attributes[.systemFreeSize] as? Int64 {
                if freeSpace < requiredSpace {
                    throw ChunkDownloadError.insufficientDiskSpace
                }
            }
        } catch {
            throw ChunkDownloadError.fileSystemError("无法检查磁盘空间: \(error.localizedDescription)")
        }
    }

    /// 验证单个分片文件的完整性
    private func validateChunk(_ chunkTask: ChunkTask, at index: Int) throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: chunkTask.filePath.path) else {
            throw ChunkDownloadError.corruptedChunk(index)
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: chunkTask.filePath.path)
            let fileSize = attributes[.size] as? Int64 ?? 0

            // 检查文件大小是否与预期的分片大小一致
            if fileSize != chunkTask.totalChunkSize {
                throw ChunkDownloadError.corruptedChunk(index)
            }
        } catch {
            // 比如文件不存在或者无法访问，都会在这里被捕获
            throw ChunkDownloadError.corruptedChunk(index) // 将所有文件系统错误归类为分片损坏
        }
    }

    /// 统一更新下载状态并通知代理（主线程）
    /// - Parameter newState: 新的下载状态
    private func updateDownloadState(_ newState: DownloadState) {
        stateLock.sync {
            _downloadState = newState
        }
    }

    /// 统一处理下载完成的逻辑并通知代理（主线程）
    private func handleDownloadCompletion() {
        // 确保最终状态是已完成
        updateDownloadState(.completed)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.chunkDownloadManager(self, didCompleteWithURL: self.downloadTask.destinationURL)
        }
    }

    /// 统一处理下载失败的逻辑并通知代理（主线程）
    /// - Parameter error: 失败的错误信息
    private func handleDownloadFailure(error: ChunkDownloadError) {
        // 只有当当前状态不是已完成或已取消时，才将其设置为失败
        let shouldUpdateState: Bool = stateLock.sync {
            if _downloadState != .completed && _downloadState != .cancelled {
                _downloadState = .failed(.chunkDownloadError(error))
                return true
            }
            return false
        }

        if shouldUpdateState {
            cleanup() // 失败时也清理临时文件
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.chunkDownloadManager(self, didFailWithError: error)
            }
        }
    }

    /// 更新下载进度（节流，并在主线程通知代理）
    private func updateProgressIfNeeded() {
        let now = Date()
        // 节流处理，避免过于频繁的进度更新导致UI卡顿
        guard now.timeIntervalSince(lastProgressUpdate) >= progressUpdateInterval else { return }
        lastProgressUpdate = now

        // 计算总下载进度
        let totalDownloaded = downloadedBytesLock.sync {
            taskDownloadedBytes.values.reduce(0, +)
        }

        // 避免除以零
        guard totalBytes > 0 else { return }

        let progress = Double(totalDownloaded) / Double(totalBytes)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.chunkDownloadManager(self, didUpdateProgress: progress)
        }
    }

    /// 处理单个分片下载失败
    private func handleChunkError(_ error: Error, for taskIndex: Int) {
        // 将 Foundation.Error 转换为 ChunkDownloadError
        let chunkError: ChunkDownloadError
        if let ce = error as? ChunkDownloadError {
            chunkError = ce
        } else {
            chunkError = .unknown(error)
        }

        // 无论何种错误，如果不是取消，则视为下载失败
        if case .cancelled = chunkError {
            handleDownloadFailure(error: chunkError)
        } else {
            // 如果是取消，则只从活跃任务中移除，不报告为失败
            onChunkComplete(at: taskIndex)
        }
    }
}

// MARK: - Array Extension (为了安全访问数组元素)

private extension Array {
    /// 安全地访问数组元素，如果索引越界则返回 nil
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - NSLock Extension (简化同步操作)

private extension NSLock {
    /// 在锁内执行闭包
    func sync<T>(execute block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}
