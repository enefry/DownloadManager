import Combine
import Foundation

/// 重试策略
public enum RetryStrategy: Codable, Equatable, Hashable, Sendable {
    /// 固定间隔重试
    case fixed(interval: TimeInterval, maxAttempts: Int)
    /// 指数退避重试
    case exponential(baseInterval: TimeInterval, maxAttempts: Int, maxInterval: TimeInterval)
    /// 自定义重试
    case custom(shouldRetry: (Error, Int) -> (TimeInterval, Bool))

    private enum CodingKeys: String, CodingKey {
        case type
        case interval
        case maxAttempts
        case baseInterval
        case maxInterval
    }

    private enum StrategyType: String, Codable {
        case fixed
        case exponential
        case custom
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .fixed(interval, maxAttempts):
            hasher.combine(".fixed(interval=\(interval), maxAttempts=\(maxAttempts))")
        case let .exponential(
            baseInterval,
            maxAttempts,
            maxInterval
        ):
            hasher.combine(".exponential(baseInterval=\(baseInterval),maxAttempts=\(maxAttempts),maxInterval=\(maxInterval)")
        case let .custom(shouldRetry):
            hasher
                .combine(
                    ".custom:shouldRetry=\(String(describing: shouldRetry))"
                )
        }
    }

    public static func == (lhs: RetryStrategy, rhs: RetryStrategy) -> Bool {
        switch (lhs, rhs) {
        case let (.fixed(interval1, maxAttempts1), .fixed(interval2, maxAttempts2),):
            return interval1 == interval2 && maxAttempts1 == maxAttempts2
        case let (.exponential(baseInterval1, maxAttempts1, maxInterval1), .exponential(baseInterval2, maxAttempts2, maxInterval2)):
            return baseInterval1 == baseInterval2 && maxAttempts1 == maxAttempts2 && maxInterval1 == maxInterval2
        default:
            return false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(StrategyType.self, forKey: .type)

        switch type {
        case .fixed:
            let interval = try container.decode(TimeInterval.self, forKey: .interval)
            let maxAttempts = try container.decode(Int.self, forKey: .maxAttempts)
            self = .fixed(interval: interval, maxAttempts: maxAttempts)
        case .exponential:
            let baseInterval = try container.decode(TimeInterval.self, forKey: .baseInterval)
            let maxAttempts = try container.decode(Int.self, forKey: .maxAttempts)
            let maxInterval = try container.decode(TimeInterval.self, forKey: .maxInterval)
            self = .exponential(baseInterval: baseInterval, maxAttempts: maxAttempts, maxInterval: maxInterval)
        case .custom:
            // 自定义重试策略无法序列化，使用默认值
            self = .fixed(interval: 5, maxAttempts: 3)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .fixed(interval, maxAttempts):
            try container.encode(StrategyType.fixed, forKey: .type)
            try container.encode(interval, forKey: .interval)
            try container.encode(maxAttempts, forKey: .maxAttempts)
        case let .exponential(baseInterval, maxAttempts, maxInterval):
            try container.encode(StrategyType.exponential, forKey: .type)
            try container.encode(baseInterval, forKey: .baseInterval)
            try container.encode(maxAttempts, forKey: .maxAttempts)
            try container.encode(maxInterval, forKey: .maxInterval)
        case .custom:
            // 自定义重试策略无法序列化，使用默认值
            try container.encode(StrategyType.custom, forKey: .type)
        }
    }

    /// 计算下次重试时间
    func nextRetryInterval(for attempt: Int, error: Error?) -> (
        TimeInterval, /// 下次重试时间
        Bool /// 是否还应该重试
    ) {
        switch self {
        case let .fixed(interval, maxAttempts):
            return (interval, attempt < maxAttempts)
        case let .exponential(baseInterval, maxAttempts, maxInterval):
            guard attempt < maxAttempts else { return (0, false) }
            let interval = baseInterval * pow(2.0, Double(attempt - 1))
            return (min(interval, maxInterval), true)
        case let .custom(shouldRetry):
            let err = error ?? DownloadError.unknown("")
            return shouldRetry(err, attempt)
        }
    }

    /// 检查是否应该重试
    func shouldRetry(error: Error, attempt: Int) -> Bool {
        nextRetryInterval(for: attempt, error: error).1
    }
}

/// 重试状态
public enum RetryState {
    /// 等待重试
    case waiting(attempt: Int, nextRetryTime: Date)
    /// 重试中
    case retrying(attempt: Int)
    /// 重试成功
    case succeeded(attempt: Int)
    /// 重试失败
    case failed(attempt: Int, error: Error)
    /// 不再重试
    case noMoreRetries(attempt: Int, error: Error)
}
