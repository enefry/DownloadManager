import Combine
import Foundation
import Network
import LoggerProxy

private let kLogTag = "DM.NM"


public class NetworkMonitor: NetworkMonitorProtocol, @unchecked Sendable {
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
        case let .connected(type):
            return type
        default:
            return .unknown
        }
    }

    public var networkTypePublisher: AnyPublisher<NetworkType, Never> {
        statusPublisher.map { status in
            switch status {
            case let .connected(type):
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

//    public static let shared = NetworkMonitor()

    // MARK: - 初始化

    public init() {
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
