import Foundation
import Network
import Combine

/// 网络类型
public enum NetworkType: String, Codable {
    case wifi
    case cellular
    case ethernet
    case unknown
}

/// 网络状态
public enum NetworkStatus {
    case connected(NetworkType)
    case disconnected
    case restricted
}

/// 网络监控器
///
/// 网络监控器负责监控网络状态和类型，包括：
/// - 监控网络连接状态
/// - 判断网络类型（WiFi/蜂窝网络）
/// - 发布网络状态变化
/// - 处理网络切换
/// - 提供网络策略建议
///
/// 使用示例：
/// ```swift
/// // 获取网络监控器实例
/// let networkMonitor = NetworkMonitor.shared
///
/// // 监听网络状态变化
/// networkMonitor.statusPublisher
///     .sink { status in
///         switch status {
///         case .connected(let type):
///             print("网络已连接，类型：\(type)")
///         case .disconnected:
///             print("网络已断开")
///         case .restricted:
///             print("网络受限")
///         }
///     }
///     .store(in: &cancellables)
///
/// // 获取当前网络状态
/// let currentStatus = networkMonitor.currentStatus
///
/// // 获取当前网络类型
/// if case .connected(let type) = currentStatus {
///     print("当前网络类型：\(type)")
/// }
/// ```
///
/// 主要功能：
/// 1. 网络监控
///    - 监控连接状态
///    - 监控网络类型
///    - 监控网络质量
///    - 发布状态更新
///
/// 2. 网络类型
///    - WiFi 网络
///    - 蜂窝网络
///    - 有线网络
///    - 未知网络
///
/// 3. 状态管理
///    - 连接状态
///    - 断开状态
///    - 受限状态
///    - 状态转换
///
/// 4. 策略控制
///    - 网络策略建议
///    - 下载策略调整
///    - 重试策略调整
///
/// 注意事项：
/// 1. 及时处理网络状态变化
/// 2. 注意网络类型限制
/// 3. 合理设置重试策略
/// 4. 注意网络切换处理
/// 5. 考虑网络质量因素
public final class NetworkMonitor {
    // MARK: - 公开属性

    public private(set) var status: NetworkStatus {
        get { statusSubject.value }
        set { statusSubject.send(newValue) }
    }

    public var statusPublisher: AnyPublisher<NetworkStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    public var isConnected: Bool {
        switch status {
        case .connected:
            return true
        case .disconnected, .restricted:
            return false
        }
    }

    public var isCellular: Bool {
        if case .connected(.cellular) = status {
            return true
        }
        return false
    }

    public var isWifi: Bool {
        if case .connected(.wifi) = status {
            return true
        }
        return false
    }

    public var currentNetworkType: NetworkType {
        switch status {
        case .connected(let type):
            return type
        default:
            return .unknown
        }
    }

    public var networkTypePublisher: AnyPublisher<NetworkType, Never> {
        statusPublisher.map { status in
            switch status {
            case .connected(let type):
                return type
            default:
                return .unknown
            }
        }.eraseToAnyPublisher()
    }

    // MARK: - 私有属性

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.downloadmanager.network", qos: .utility)
    private let statusSubject = CurrentValueSubject<NetworkStatus, Never>(.disconnected)

    // MARK: - 单例

    public static let shared = NetworkMonitor()

    // MARK: - 初始化

    private init() {
        setupMonitor()
    }

    deinit {
        monitor.cancel()
    }

    // MARK: - 公开方法

    /// 开始监控网络状态
    public func startMonitoring() {
        monitor.start(queue: queue)
    }

    /// 停止监控网络状态
    public func stopMonitoring() {
        monitor.cancel()
    }

    // MARK: - 私有方法

    private func setupMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            let status: NetworkStatus

            if path.status == .satisfied {
                if path.usesInterfaceType(.wifi) {
                    status = .connected(.wifi)
                } else if path.usesInterfaceType(.cellular) {
                    status = .connected(.cellular)
                } else if path.usesInterfaceType(.wiredEthernet) {
                    status = .connected(.ethernet)
                } else {
                    status = .connected(.unknown)
                }
            } else {
                status = .disconnected
            }

            DispatchQueue.main.async {
                self.status = status
            }
        }

        monitor.start(queue: queue)
    }
}