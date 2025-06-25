import Combine
import ConcurrencyCollection
import Foundation

/// 下载器工厂类管理器
public class CustomRetryStrategyCenter: @unchecked Sendable {
    public typealias CustomRetryStrategy = (_ attempt: Int, _ error: Error?, _ context: [String: String]) async -> (TimeInterval, Bool)
    public static let shared = CustomRetryStrategyCenter()
    private let customRetryStrategys: ConcurrentDictionary<String, CustomRetryStrategy> = ConcurrentDictionary()

    /// 注册下载器工厂类
    public func register(customRetryStrategy: @escaping CustomRetryStrategy, for identifier: String) {
        customRetryStrategys[identifier] = customRetryStrategy
    }

    /// 注销下载器工厂类
    public func unregister(for identifier: String) {
        customRetryStrategys[identifier] = nil
    }

    public func nextRetryInterval(for identifier: String, attempt: Int, error: Error?, context: [String: String]) async -> (TimeInterval, Bool)? {
        if let strategy = customRetryStrategys[identifier] {
            return await strategy(attempt, error, context)
        }
        return nil
    }
}

/// 重试策略
public enum RetryStrategy: Codable, Equatable, Hashable, Sendable {
    /// 固定间隔重试
    case fixed(interval: TimeInterval, maxAttempts: Int)
    /// 指数退避重试
    case exponential(baseInterval: TimeInterval, maxAttempts: Int, maxInterval: TimeInterval)
    /// 自定义重试
    case custom(identifier: String, context: [String: String])

    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .fixed(interval, maxAttempts):
            hasher.combine(".fixed")
            hasher.combine(interval)
            hasher.combine(maxAttempts)
        case let .exponential(
            baseInterval,
            maxAttempts,
            maxInterval
        ):
            hasher.combine(".exponential")
            hasher.combine(baseInterval)
            hasher.combine(maxAttempts)
            hasher.combine(maxInterval)
        case let .custom(identifier, context):
            hasher.combine("custom")
            hasher.combine(identifier)
            hasher.combine(context)
        }
    }

    public static func == (lhs: RetryStrategy, rhs: RetryStrategy) -> Bool {
        switch (lhs, rhs) {
        case let (.fixed(interval1, maxAttempts1), .fixed(interval2, maxAttempts2),):
            return interval1 == interval2 && maxAttempts1 == maxAttempts2
        case let (.exponential(baseInterval1, maxAttempts1, maxInterval1), .exponential(baseInterval2, maxAttempts2, maxInterval2)):
            return baseInterval1 == baseInterval2 && maxAttempts1 == maxAttempts2 && maxInterval1 == maxInterval2
        case let (.custom(id1, ctx1), .custom(id2, ctx2)):
            return id1 == id2 && ctx1 == ctx2
        default:
            return false
        }
    }

    /// 计算下次重试时间
    func nextRetryInterval(for attempt: Int, error: Error?) async -> (
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
        case let .custom(id, ctx):
            if let ret = await CustomRetryStrategyCenter.shared.nextRetryInterval(for: id, attempt: attempt, error: error, context: ctx) {
                return ret
            }
        }
        return (0, false)
    }

    /// 检查是否应该重试
    func shouldRetry(error: Error, attempt: Int) async -> Bool {
        return await nextRetryInterval(for: attempt, error: error).1
    }
}
