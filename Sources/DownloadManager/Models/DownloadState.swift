import Foundation

/// 下载状态
public enum DownloadState: Codable, Equatable {
    
    /// 等待中
    case waiting

    /// 准备中
    case preparing

    /// 下载中
    case downloading

    /// 暂停中
    case paused

    /// 已完成
    case completed

    /// 已取消
    case cancelled

    /// 失败
    case failed(DownloadError)
    
    
    // Codable 实现
    enum CodingKeys: String, CodingKey {
        case waiting, preparing, downloading, paused, completed, failed, cancelled, errorCode, errorDescription
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .waiting:
            try container.encode("waiting", forKey: .waiting)
        case .preparing:
            try container.encode("preparing", forKey: .preparing)
        case .downloading:
            try container.encode("downloading", forKey: .downloading)
        case .paused:
            try container.encode("paused", forKey: .paused)
        case .completed:
            try container.encode("completed", forKey: .completed)
        case let .failed(error):
            try container.encode("failed", forKey: .failed)
            try container.encode(error.errorCode, forKey: .errorCode)
            try container.encode(error.localizedDescription, forKey: .errorDescription)
        case .cancelled:
            try container.encode("cancelled", forKey: .cancelled)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.waiting) {
            self = .waiting
        } else if container.contains(.preparing) {
            self = .preparing
        } else if container.contains(.downloading) {
            self = .downloading
        } else if container.contains(.paused) {
            self = .paused
        } else if container.contains(.completed) {
            self = .completed
        } else if container.contains(.failed) {
            let errorDesc = try container.decodeIfPresent(String.self, forKey: .errorDescription) ?? ""
            let errorCode = try container.decodeIfPresent(
                Int.self,
                forKey: .errorCode
            ) ?? -1
            let error = DownloadError.from(
                description: errorDesc,
                code: errorCode
            )
            self = .failed(DownloadError.from(error))
        } else if container.contains(.cancelled) {
            self = .cancelled
        } else {
            self = .waiting
        }
    }

    /// 比较两个下载状态是否相等
    public static func == (lhs: DownloadState, rhs: DownloadState) -> Bool {
        switch (lhs, rhs) {
        case (.waiting, .waiting),
             (.preparing, .preparing),
             (.downloading, .downloading),
             (.paused, .paused),
             (.completed, .completed),
             (.cancelled, .cancelled):
            return true
        case let (.failed(error1), .failed(error2)):
            return error1.localizedDescription == error2.localizedDescription
        default:
            return false
        }
    }

    /// 获取状态的描述
    public var description: String {
        switch self {
        case .waiting:
            return "等待中"
        case .preparing:
            return "准备中"
        case .downloading:
            return "下载中"
        case .paused:
            return "已暂停"
        case .completed:
            return "已完成"
        case .cancelled:
            return "已取消"
        case let .failed(error):
            return "失败: \(error.localizedDescription)"
        }
    }

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
        case .waiting, .paused, .failed:
            return true
        default:
            return false
        }
    }

    /// 检查状态是否表示任务可以暂停
    public var canPause: Bool {
        switch self {
        case .downloading:
            return true
        default:
            return false
        }
    }

    /// 检查状态是否表示任务可以取消
    public var canCancel: Bool {
        switch self {
        case .waiting, .preparing, .downloading, .paused:
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
