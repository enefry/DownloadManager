import Foundation

/// 下载任务配置协议
public struct DownloadTaskConfiguration: Codable {
    /// 下载超时时间
    var timeoutInterval: TimeInterval = -1

    /// 自定义请求头
    var headers: [String: String] = [:]

    /// 支持分片下载
    var supportChunkDownload: Bool? = nil

    /// 分片大小（字节）
    var chunkSize: Int64 = 4 * 1024 * 1024

    /// 最大并发分片数
    var maxConcurrentChunks: Int = .max

    /// 下载速度限制（字节/秒），0 表示不限制
    var speedLimit: Int64 = 0

    /// 下载优先级（0-100）
    var priority: Int = 100

    /// 是否允许在后台下载
    var allowsBackgroundDownload: Bool?

    /// 是否允许在蜂窝网络下载
    var allowsCellularAccess: Bool?

    /// 是否允许在受限网络下载
    var allowsConstrainedNetworkAccess: Bool?

    /// 是否允许在昂贵网络下载
    var allowsExpensiveNetworkAccess: Bool?

    /// 文件完整性校验类型
    var integrityCheck: IntegrityCheckType?

    /// 重试策略
    var retryStrategy: RetryStrategy?
}
