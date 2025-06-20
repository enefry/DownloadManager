import Combine
import Foundation

public final class DownloadTask: DownloadTaskProtocol, Codable {
    // MARK: - 公开属性

    /// 唯一标识，其实就是源URL+目标URL的 hash
    public let identifier: String
    /// 任务配置，必须存在
    public var taskConfigure: DownloadTaskConfiguration
    /// 任务添加时间
    public var startTime: TimeInterval
    /// 任务恢复下载时间
    public var resumeTime: TimeInterval

    // 源 URL
    public let url: URL
    // 目标 URL
    public let destinationURL: URL
    /// 已经下载大小
    public private(set) var downloadedBytes: Int64 = 0
    /// 总大小，对于未知下子大小，这个值为-1
    public private(set) var totalBytes: Int64 = -1

    /// 进度发布者
    public var progressPublisher: AnyPublisher<(Int64, Int64), Never> {
        progressSubject.eraseToAnyPublisher()
    }

    /// 状态发布者
    public var statePublisher: AnyPublisher<DownloadState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    /// 速度发布者
    public var speedPublisher: AnyPublisher<Double, Never> {
        speedSubject.eraseToAnyPublisher()
    }

    // MARK: - 私有属性

    // 内部配置

    /// 分片下载管理，每个下载任务一个分片管理器
//    internal weak var chunkDownloadManager: ChunkDownloadManager?

    /// 统计下载速度定时器
    internal var speedTimer: Timer?
    /// 最后下载大小
    internal var lastDownloadedBytes: Int64 = 0

    /// 发布者的subject
    internal let stateSubject: CurrentValueSubject<DownloadState, Never>
    internal let progressSubject = CurrentValueSubject<(Int64, Int64), Never>((0, 0))
    internal let speedSubject = CurrentValueSubject<Double, Never>(0)

    /// 订阅的句柄
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case identifier
        case taskConfigure
        case startTime
        case resumeTime
        case url
        case destinationURL
        case downloadedBytes
        case totalBytes
        case state
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        identifier = try container.decode(String.self, forKey: .identifier)
        taskConfigure = try container.decode(DownloadTaskConfiguration.self, forKey: .taskConfigure)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        resumeTime = try container.decode(TimeInterval.self, forKey: .resumeTime)
        url = try container.decode(URL.self, forKey: .url)
        destinationURL = try container.decode(URL.self, forKey: .destinationURL)
        downloadedBytes = try container.decode(Int64.self, forKey: .downloadedBytes)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)

        let state = try container.decode(DownloadState.self, forKey: .state)
        stateSubject = CurrentValueSubject<DownloadState, Never>(state)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(identifier, forKey: .identifier)
        try container.encode(taskConfigure, forKey: .taskConfigure)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(resumeTime, forKey: .resumeTime)
        try container.encode(url, forKey: .url)
        try container.encode(destinationURL, forKey: .destinationURL)
        try container.encode(downloadedBytes, forKey: .downloadedBytes)
        try container.encode(totalBytes, forKey: .totalBytes)
        try container.encode(stateSubject.value, forKey: .state)
    }

    // MARK: - 初始化方法

    public init(
        url: URL,
        destinationURL: URL,
        identifier: String? = nil,
        configuration: DownloadTaskConfiguration
    ) {
        self.url = url
        self.destinationURL = destinationURL
        taskConfigure = configuration
        self.identifier = identifier ?? DownloadTask.buildIdentifier(
            url: url,
            destinationURL: destinationURL
        )
        startTime = Date().timeIntervalSince1970
        resumeTime = 0
        stateSubject = CurrentValueSubject<DownloadState, Never>(.initialed)
    }

    public static func buildIdentifier(url: URL, destinationURL: URL) -> String {
        return "\(url.absoluteString)\n\(destinationURL.absoluteString)".dm_sha256()
    }

    // MARK: - 公开控制方法

//
//    public func start() {
//        Task {
//            await chunkDownloadManager?.start()
//        }
//    }
//
//    /// 暂停下载任务
//    public func pause() {
//        Task {
//            await chunkDownloadManager?.pause()
//        }
//    }
//
//    /// 恢复下载任务
//    public func resume() {
//        Task {
//            await chunkDownloadManager?.resume()
//        }
//    }
//
//    /// 取消下载任务
//    public func cancel() {
//        Task {
//            await chunkDownloadManager?.cancel()
//        }
//    }

    /// 获取当前状态
    public var state: DownloadState {
        stateSubject.value
    }

    /// 重试次数
    public var retryCount: Int = 0
}
