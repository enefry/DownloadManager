import Atomics
import Combine
import DownloadManagerBasic
import Foundation

@propertyWrapper
public struct DMAtomicInteger<Value: AtomicValue & FixedWidthInteger>: @unchecked Sendable where Value.AtomicRepresentation.Value == Value {
    private var atomValue: ManagedAtomic<Value>

    public var wrappedValue: Value {
        get { atomValue.load(ordering: .acquiring) }
        set { atomValue.store(newValue, ordering: .releasing) }
    }

    public init(wrappedValue: Value) {
        atomValue = ManagedAtomic(wrappedValue)
    }
}

/**
 * 下载任务，记录一个具体下载任务的配置
 */
public final class DownloadTask: DownloadTaskProtocol, Codable, @unchecked Sendable, Equatable {
    public static func == (lhs: DownloadTask, rhs: DownloadTask) -> Bool {
        lhs.identifier == rhs.identifier
    }

    // MARK: - 公开属性

    /// 唯一标识，其实就是源URL+目标URL的 hash
    public let identifier: String

    /// 任务配置，必须存在
    public let taskConfigure: DownloadTaskConfiguration

    /// 任务添加时间
    public let startTime: TimeInterval

    /// 任务恢复下载时间

    @DMAtomicInteger
    public var resumeTime: Int64

    // 源 URL
    public let url: URL

    // 目标 URL
    public let destinationURL: URL

    /// 已经下载大小

    @DMAtomicInteger
    public var downloadedBytes: Int64

    /// 总大小，对于未知下子大小，这个值为-1
    @DMAtomicInteger
    public var totalBytes: Int64

    // 进度
    public var progress: DownloadProgress { progressSubject.value }

    /// 进度发布者
    public var progressPublisher: AnyPublisher<DownloadProgress, Never> {
        progressSubject.eraseToAnyPublisher()
    }

    /// 状态发布者
    public var statePublisher: AnyPublisher<TaskState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    /// 速度发布者
    public var speedPublisher: AnyPublisher<Double, Never> {
        speedSubject.eraseToAnyPublisher()
    }

    // MARK: - 私有属性

    /// 发布者的subject
    private let stateSubject: CurrentValueSubject<TaskState, Never>
    public func update(state: TaskState) async {
        stateSubject.send(state)
    }

    /// 进度发布者subject
    private let progressSubject = CurrentValueSubject<DownloadProgress, Never>(DownloadProgress(timestamp: 0, downloadedBytes: 0, totalBytes: 0))
    public func update(progress: DownloadProgress) async {
        progressSubject.send(progress)
    }

    /// 速度发布者subject
    private let speedSubject = CurrentValueSubject<Double, Never>(0)
    public func update(speed: Double) {
        speedSubject.send(speed)
    }

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
        resumeTime = try container.decode(Int64.self, forKey: .resumeTime)
        url = try container.decode(URL.self, forKey: .url)
        destinationURL = try container.decode(URL.self, forKey: .destinationURL)
        downloadedBytes = try container.decode(Int64.self, forKey: .downloadedBytes)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
        let state = try container.decode(TaskState.self, forKey: .state)
        stateSubject = CurrentValueSubject<TaskState, Never>(state)
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
        stateSubject = CurrentValueSubject<TaskState, Never>(.pending)
        downloadedBytes = 0
        totalBytes = -1
    }

    public static func buildIdentifier(url: URL, destinationURL: URL) -> String {
        return "\(url.absoluteString)\n\(destinationURL.absoluteString)".dm_sha256()
    }

    /// 获取当前状态
    public var state: TaskState {
        stateSubject.value
    }

    /// 重试次数
    public var retryCount: Int = 0
}

extension DownloadTask {
    func downloadProtocol() -> ProtocolType? {
        if let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                return .http
            case "ftp", "ftps":
                return .ftp
            case "smb", "samba":
                return .samba
            case "magnet":
                return .magnet
            default:
                return .init(rawValue: scheme)
            }
        }
        return nil
    }
}
