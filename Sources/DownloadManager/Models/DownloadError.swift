import Foundation

/// 下载错误类型
public enum DownloadError: Error {
    /// 无效的URL
    case invalidURL

    /// 网络错误
    case networkError(String)

    /// 文件系统错误
    case fileSystemError(String)

    /// 磁盘空间不足
    case insufficientDiskSpace

    /// 下载被取消
    case cancelled

    /// 下载超时
    case timeout

    /// 服务器错误
    case serverError(Int)

    /// 完整性校验失败
    case integrityCheckFailed(String)

    /// 未知错误
    case unknown(String)

    /// chunk 下载失败
    case chunkDownloadError(ChunkDownloadError)

    /// 错误恢复建议
    public var recoverySuggestion: String? {
        switch self {
        case .invalidURL:
            return "请检查URL是否正确"
        case .networkError:
            return "请检查网络连接"
        case .fileSystemError:
            return "请检查文件系统权限"
        case .insufficientDiskSpace:
            return "请清理磁盘空间"
        case .cancelled:
            return "下载已被用户取消"
        case .timeout:
            return "请检查网络连接并重试"
        case .serverError:
            return "请稍后重试"
        case .integrityCheckFailed:
            return "请重新下载文件"
        case let .chunkDownloadError(error):
            return "请重新下载文件"
        case .unknown:
            return "请重试或联系支持"
        }
    }

    /// 错误描述
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的URL"
        case let .networkError(error):
            return "网络错误: \(error)"
        case let .fileSystemError(error):
            return "文件系统错误: \(error)"
        case .insufficientDiskSpace:
            return "磁盘空间不足"
        case .cancelled:
            return "下载已取消"
        case .timeout:
            return "下载超时"
        case let .serverError(code):
            return "服务器错误: HTTP \(code)"
        case let .integrityCheckFailed(error):
            return "文件完整性校验失败: \(error)"
        case let .chunkDownloadError(error):
            return "分片下载失败:\(error)"
        case let .unknown(error):
            return "未知错误: \(error)"
        }
    }

    /// 错误代码
    public var errorCode: Int {
        switch self {
        case .invalidURL:
            return 1001
        case .networkError:
            return 1002
        case .fileSystemError:
            return 1003
        case .insufficientDiskSpace:
            return 1004
        case .cancelled:
            return 1005
        case .timeout:
            return 1006
        case let .serverError(code):
            return code
        case .integrityCheckFailed:
            return 1007
        case let .chunkDownloadError(error):
            return 0xF00000 & error.errorCode
        case .unknown:
            return 9999
        }
    }

    /// 从错误描述和错误代码创建下载错误
    /// - Parameters:
    ///   - description: 错误描述
    ///   - code: 错误代码
    /// - Returns: 对应的下载错误
    public static func from(description: String, code: Int) -> DownloadError {
        // 移除错误描述中的前缀
        let cleanDescription = description
            .replacingOccurrences(of: "网络错误: ", with: "")
            .replacingOccurrences(of: "文件系统错误: ", with: "")
            .replacingOccurrences(of: "服务器错误: HTTP ", with: "")
            .replacingOccurrences(of: "文件完整性校验失败: ", with: "")
            .replacingOccurrences(of: "未知错误: ", with: "")

        switch code {
        case 1001:
            return .invalidURL
        case 1002:
            return .networkError(cleanDescription)
        case 1003:
            return .fileSystemError(cleanDescription)
        case 1004:
            return .insufficientDiskSpace
        case 1005:
            return .cancelled
        case 1006:
            return .timeout
        case 1007:
            return .integrityCheckFailed(cleanDescription)
        case 9999:
            return .unknown(cleanDescription)
        default:
            if code >= 400 && code < 600 {
                return .serverError(code)
            }
            return .unknown(cleanDescription)
        }
    }

    /// 是否可重试
    public var isRetryable: Bool {
        switch self {
        case .networkError, .timeout, .serverError, .integrityCheckFailed,
             .chunkDownloadError:
            return true
        case .invalidURL, .fileSystemError, .insufficientDiskSpace, .cancelled, .unknown:
            return false
        }
    }

    /// 从 NSError 创建下载错误
    /// - Parameter error: NSError 实例
    /// - Returns: 对应的下载错误
    public static func from(_ error: Error) -> DownloadError {
        let nsError = error as NSError

        switch nsError.domain {
        case NSURLErrorDomain:
            switch nsError.code {
            case NSURLErrorCancelled:
                return .cancelled
            case NSURLErrorTimedOut:
                return .timeout
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost:
                return .networkError(error.localizedDescription)
            default:
                return .networkError(error.localizedDescription)
            }
        case NSCocoaErrorDomain:
            switch nsError.code {
            case NSFileNoSuchFileError,
                 NSFileReadNoPermissionError,
                 NSFileWriteNoPermissionError:
                return .fileSystemError(error.localizedDescription)
            case NSFileWriteOutOfSpaceError:
                return .insufficientDiskSpace
            default:
                return .fileSystemError(error.localizedDescription)
            }
        default:
            return .unknown(error.localizedDescription)
        }
    }
}
