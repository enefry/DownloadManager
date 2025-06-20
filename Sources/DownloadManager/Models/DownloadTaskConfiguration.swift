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

    public struct NetworkProxy: Codable, Copyable, Equatable, Hashable {
        public struct Pair: Codable, Copyable, Equatable, Hashable {
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
                result[String(kCFNetworkProxiesHTTPSEnable)] = true
                result[String(kCFNetworkProxiesHTTPSProxy)] = https.address
                result[String(kCFNetworkProxiesHTTPSPort)] = https.port
            }
            if let socks = socks {
                result[String(kCFNetworkProxiesSOCKSEnable)] = true
                result[String(kCFNetworkProxiesSOCKSProxy)] = socks.address
                result[String(kCFNetworkProxiesSOCKSPort)] = socks.port
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
}
