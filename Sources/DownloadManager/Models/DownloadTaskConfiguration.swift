import CFNetwork
import Foundation
/// 下载任务配置协议
public struct DownloadTaskConfiguration: Codable, Equatable, Hashable, Sendable {
    /// 自定义请求头
    public var headers: [String: String] = [:]

    /// session配置下载请求超时时间
    public var timeoutIntervalForRequest: TimeInterval?
    /// session配置下载超时时间
    public var timeoutIntervalForResource: TimeInterval?

    /// task的超时时间
    public var timeoutInterval: TimeInterval?
    /// 支持分片下载
    public var supportChunkDownload: Bool? = nil

    /// 分片大小（字节）
    public var chunkSize: Int64 = 4 * 1024 * 1024

    /// 最大并发分片数
    public var maxConcurrentChunks: Int = .max

    /// 下载优先级（0-100）
    public var priority: Int = 100

    /// 是否允许在后台下载
    public var allowsBackgroundDownload: Bool?

    /// 是否允许在蜂窝网络下载
    public var allowCellularDownloads: Bool?

    /// 是否允许在受限网络下载
    public var allowsConstrainedNetworkAccess: Bool?

    /// 是否允许在昂贵网络下载
    public var allowsExpensiveNetworkAccess: Bool?

    /// 网络协议实现
    public var protocolClasses: [String]?

    public struct NetworkProxy: Codable, Copyable, Equatable, Hashable, Sendable {
        public struct Pair: Codable, Copyable, Equatable, Hashable, Sendable {
            let address: String
            let port: Int
        }

        public var http: Pair?
        public var https: Pair?
        public var socks: Pair?
        func toDict() -> [String: Any] {
            var result = [String: Any]()
            if let http = http {
                result[String(kCFNetworkProxiesHTTPEnable)] = true
                result[String(kCFNetworkProxiesHTTPProxy)] = http.address
                result[String(kCFNetworkProxiesHTTPPort)] = http.port
            }
            if let https = https {
                result["HTTPSEnable"] = true
                result["HTTPSProxy"] = https.address
                result["HTTPSPort"] = https.port
            }
            if let socks = socks {
                result["SOCKSEnable"] = true
                result["SOCKSProxy"] = socks.address
                result["SOCKSPort"] = socks.port
            }
            return result
        }
    }

    /// 网络代理
    public var connectionProxy: NetworkProxy? = nil

    /// 重试策略
    public var retryStrategy: RetryStrategy?

    /// 文件完整性校验类型
    public var integrityCheck: IntegrityCheckType?

    func urlSessionConfigure() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default

        // 设置请求头
        if !headers.isEmpty {
            configuration.httpAdditionalHeaders = headers
        }

        // 设置超时时间
        if let timeoutInterval = timeoutIntervalForRequest {
            configuration.timeoutIntervalForRequest = timeoutInterval
        }
        if let timeoutInterval = timeoutIntervalForResource {
            configuration.timeoutIntervalForResource = timeoutInterval
        }

        // 设置网络访问权限
        if let allowsBackgroundDownload = allowsBackgroundDownload {
            configuration.isDiscretionary = allowsBackgroundDownload
        }

        if let allowCellularDownloads = allowCellularDownloads {
            configuration.allowsCellularAccess = allowCellularDownloads
        }

        if let allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess {
            configuration.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        }

        if let allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess {
            configuration.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        }

        // 设置代理
        if let connectionProxy = connectionProxy {
            configuration.connectionProxyDictionary = connectionProxy.toDict()
        }

        if let protocolClasses = protocolClasses {
            configuration.protocolClasses = protocolClasses.compactMap({ NSClassFromString($0) })
        }
        return configuration
    }

    public init(headers: [String: String] = [:], timeoutIntervalForRequest: TimeInterval? = nil, timeoutIntervalForResource: TimeInterval? = nil, timeoutInterval: TimeInterval? = nil, supportChunkDownload: Bool? = nil, chunkSize: Int64 = 4 * 1024 * 1024, maxConcurrentChunks: Int = 4, priority: Int = 100, allowsBackgroundDownload: Bool? = nil, allowCellularDownloads: Bool? = nil, allowsConstrainedNetworkAccess: Bool? = nil, allowsExpensiveNetworkAccess: Bool? = nil, protocolClasses: [String]? = nil, connectionProxy: NetworkProxy? = nil, retryStrategy: RetryStrategy? = nil, integrityCheck: IntegrityCheckType? = nil) {
        self.headers = headers
        self.timeoutIntervalForRequest = timeoutIntervalForRequest
        self.timeoutIntervalForResource = timeoutIntervalForResource
        self.timeoutInterval = timeoutInterval
        self.supportChunkDownload = supportChunkDownload
        self.chunkSize = chunkSize
        self.maxConcurrentChunks = maxConcurrentChunks
        self.priority = priority
        self.allowsBackgroundDownload = allowsBackgroundDownload
        self.allowCellularDownloads = allowCellularDownloads
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.protocolClasses = protocolClasses
        self.connectionProxy = connectionProxy
        self.retryStrategy = retryStrategy
        self.integrityCheck = integrityCheck
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        headers = try container.decode([String: String].self, forKey: .headers)
        timeoutIntervalForRequest = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutIntervalForRequest)
        timeoutIntervalForResource = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutIntervalForResource)
        timeoutInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutInterval)
        supportChunkDownload = try container.decodeIfPresent(Bool.self, forKey: .supportChunkDownload)
        chunkSize = try container.decode(Int64.self, forKey: .chunkSize)
        maxConcurrentChunks = try container.decode(Int.self, forKey: .maxConcurrentChunks)
        priority = try container.decode(Int.self, forKey: .priority)
        allowsBackgroundDownload = try container.decodeIfPresent(Bool.self, forKey: .allowsBackgroundDownload)
        allowCellularDownloads = try container.decodeIfPresent(Bool.self, forKey: .allowCellularDownloads)
        allowsConstrainedNetworkAccess = try container.decodeIfPresent(Bool.self, forKey: .allowsConstrainedNetworkAccess)
        allowsExpensiveNetworkAccess = try container.decodeIfPresent(Bool.self, forKey: .allowsExpensiveNetworkAccess)
        protocolClasses = try container.decodeIfPresent([String].self, forKey: .protocolClasses)
        connectionProxy = try container.decodeIfPresent(DownloadTaskConfiguration.NetworkProxy.self, forKey: .connectionProxy)
        retryStrategy = try container.decodeIfPresent(RetryStrategy.self, forKey: .retryStrategy)
        integrityCheck = try container.decodeIfPresent(IntegrityCheckType.self, forKey: .integrityCheck)
    }
}
