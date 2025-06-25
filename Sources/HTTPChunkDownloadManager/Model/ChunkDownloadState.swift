import DownloadManagerBasic
import Foundation

/// 下载状态
public enum ChunkDownloadState: CustomStringConvertible, Codable, Sendable, Hashable, Equatable {
    /// 等待中
    case initialed

    /// 准备中
    case preparing

    /// 下载中
    case downloading

    /// 暂停中
    case paused

    /// 下载完成，文件合并中
    case merging

    /// 已完成
    case completed

    /// 已取消
    case cancelled

    /// 失败
    case failed(DownloadError)

    public var description: String {
        switch self {
        case .initialed:
            return "等待中"
        case .preparing:
            return "准备中"
        case .downloading:
            return "下载中"
        case .paused:
            return "已暂停"
        case .merging:
            return "合并中"
        case .completed:
            return "已完成"
        case .cancelled:
            return "已取消"
        case let .failed(error):
            return "失败: \(error.localizedDescription)"
        }
    }
}

/// 快速状态判断
extension ChunkDownloadState {
    /// 检查状态是否表示任务已完成（成功或失败）
    public var isFinished: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            return true
        default:
            return false
        }
    }

    /// 检查状态是否表示任务可以继续
    public var canResume: Bool {
        switch self {
        case .initialed, .paused, .failed:
            return true
        default:
            return false
        }
    }

    /// 检查状态是否表示任务可以暂停
    public var canPause: Bool {
        switch self {
        case .downloading, .preparing:
            return true
        default:
            return false
        }
    }

    /// 检查状态是否表示任务可以取消
    public var canCancel: Bool {
        switch self {
        case .initialed, .preparing, .downloading, .paused:
            return true
        default:
            return false
        }
    }

    public var isFailed: Bool {
        if case .failed = self {
            return true
        } else {
            return false
        }
    }
}
