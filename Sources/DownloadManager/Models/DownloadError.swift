import DownloadManagerBasic
import Foundation

/// 下载错误类型
///
public enum DownloadManagerErrorCode: Int {
    case OFFSET = 0x0F1000
    /// 无效的URL
    case invalidURL
    /// 网络错误
    case networkError
    /// 文件系统错误
    case fileSystemError
    /// 磁盘空间不足
    case insufficientDiskSpace

    case downloaderError

    /// 完整性校验失败
    case integrityCheckFailed

    case END

    static func isDownloadManagerError(error: DownloadError) -> Bool {
        if error.code > OFFSET.rawValue && error.code < END.rawValue {
            return true
        }
        return false
    }
}

extension DownloadError {
    
}
