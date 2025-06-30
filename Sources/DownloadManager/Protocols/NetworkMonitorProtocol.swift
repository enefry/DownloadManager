//
//  NetworkMonitorProtocol.swift
//  DownloadManager
//
//  Created by chen on 2025/6/21.
//

import Combine
import Foundation
import Network

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

public protocol NetworkMonitorProtocol {
    var status: NetworkStatus { get }
    var statusPublisher: AnyPublisher<NetworkStatus, Never> { get }
    var isConnected: Bool { get }
    var isCellular: Bool { get }
    var isWifi: Bool { get }
    var currentNetworkType: NetworkType { get }
    var networkTypePublisher: AnyPublisher<NetworkType, Never> { get }
    func startMonitoring()
    func stopMonitoring()
}
