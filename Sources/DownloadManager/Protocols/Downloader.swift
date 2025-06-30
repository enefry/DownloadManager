//
//  Downloader.swift
//  DownloadManager
//
//  Created by chen on 2025/6/22.
//
import Combine
import ConcurrencyCollection
import DownloadManagerBasic
import Foundation
import LoggerProxy

fileprivate let kLogTag = "DM.DF"

/// 下载任务协议
public protocol DownloadTaskProtocol: AnyObject, Sendable {
    /// 下载任务的唯一标识符
    var identifier: String { get }
    /// 下载任务配置
    var taskConfigure: DownloadTaskConfiguration { get }
    /// 源地址的URL
    var url: URL { get }
    /// 目标保存路径
    var destinationURL: URL { get }
    /// 已下载字节数
    var downloadedBytes: Int64 { get }
    /// 总字节数
    var totalBytes: Int64 { get }
    /// 开始下载时间
    var startTime: TimeInterval { get }
    /// 当前状态
    var state: TaskState { get }
    /// 当前进度
    var progress: DownloadProgress { get }
    /// 进度发布者
    var progressPublisher: AnyPublisher<DownloadProgress, Never> { get }
    // 速度发布者
    var speedPublisher: AnyPublisher<DownloadManagerSpeed, Never> { get }
    /// 状态发布者
    var statePublisher: AnyPublisher<TaskState, Never> { get }
}

/// 下载器支持的协议
public enum ProtocolType: String {
    case http // http 下载
    case ftp // ftp下载
    case samba = "smb" // samba协议下子
    case magnet // 磁力连接
}

/// 下载状态
public enum DownloaderState: Hashable, Equatable, Sendable, Codable {
    case initial // 准备中
    case downloading // 下载中
    case paused // 暂停中
    case stop // 停止
    case completed // 完成
    case failed(DownloadError) // 失败

    private enum CodingKeys: String, CodingKey {
        case type
        case code
        case value
    }

    private enum CodingType: String, Codable, Sendable, Equatable, Hashable {
        case initial // 准备中
        case downloading // 下载中
        case paused // 暂停中
        case stop // 停止
        case completed // 完成
        case failed // 失败
    }

    private var codingType: CodingType {
        switch self {
        case .initial: return .initial
        case .downloading: return .downloading
        case .paused: return .paused
        case .stop: return .stop
        case .completed: return .completed
        case .failed: return .failed
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(codingType, forKey: .type)
        if case let .failed(error) = self {
            try container.encode(error.code, forKey: .code)
            try container.encode(error.description, forKey: .code)
        }
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(CodingType.self, forKey: .type)
        switch type {
        case .initial: self = .initial
        case .downloading: self = .downloading
        case .paused: self = .paused
        case .stop: self = .stop
        case .completed: self = .completed
        case .failed:
            let code = try container.decode(Int.self, forKey: .code)
            let desc = try container.decode(String.self, forKey: .value)
            self = .failed(DownloadError(code: code, description: desc))
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(codingType)
        if case let .failed(error) = self {
            hasher.combine(error.code)
            hasher.combine(error.description)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.initial, .initial), (.downloading, .downloading), (.paused, .paused), (.stop, .stop), (.completed, .completed):
            return true
        case let (.failed(error1), .failed(error2)):
            return error1.code == error2.code && error1.description == error2.description
        default:
            return false
        }
    }

    func toTaskState() -> TaskState {
        switch self {
        case .initial: return .pending // 准备中
        case .downloading: return .downloading // 下载中
        case .paused: return .paused // 暂停中
        case .stop: return .stop // 停止
        case .completed: return .completed // 完成
        case let .failed(downloadError): return .failed(downloadError) // 失败
        }
    }
}

/// 协议下载器
public protocol Downloader: AnyObject, Sendable {
    var state: DownloaderState { get async }
    /// 支持的协议
    var supportProtocols: [ProtocolType] { get }
    /// 开始
    func start() async
    /// 暂停
    func pause() async
    /// 恢复
    func resume() async
    /// 取消
    func cancel() async
    /// 清理资源
    func cleanup() async
}

/// 下载器代理
public protocol DownloaderDelegate {
    /// 下载进度
    func downloader(_ downloader: any Downloader, task: DownloadTaskProtocol, didUpdateProgress progress: DownloadProgress) async
    /// 下载状态变化
    func downloader(_ downloader: any Downloader, task: DownloadTaskProtocol, didUpdateState state: DownloaderState) async
    /// 下载完成
    func downloader(_ downloader: any Downloader, didCompleteWith task: DownloadTaskProtocol) async
    /// 下载异常
    func downloader(_ downloader: any Downloader, task: DownloadTaskProtocol, didFailWithError error: Error) async
}

/// 下载器工厂类
public protocol DownloaderFactory: AnyObject {
    func downloader(for: ProtocolType, task: DownloadTaskProtocol, delegate: DownloaderDelegate) async throws -> Downloader
}

/// 下载器工厂类管理器
public class DownloaderFactoryCenter: @unchecked Sendable {
    public static let shared = DownloaderFactoryCenter()
    private let downloaders: ConcurrentDictionary<ProtocolType, [DownloaderFactory]> = ConcurrentDictionary()

    /// 注册下载器工厂类
    public func register(factory: DownloaderFactory, for type: ProtocolType) {
        downloaders.safeWrite { data in
            var factorys = data[type] ?? []
            factorys.insert(factory, at: 0)
            data[type] = factorys
        }
    }

    /// 注销下载器工厂类
    public func unregister(factory: DownloaderFactory, for type: ProtocolType) {
        downloaders.safeWrite({ data in
            data[type]?.removeAll(where: { $0 === factory })
        })
    }

    /// 获取工厂类
    public func factory(for type: ProtocolType) -> [DownloaderFactory] {
        downloaders.getValue(key: type) ?? []
    }
}

/// 下载器创建扩展
public extension DownloaderFactoryCenter {
    func downloader(for type: ProtocolType, task: DownloadTaskProtocol, delegate: any DownloaderDelegate) async -> Downloader? {
        for factory in factory(for: type) {
            do {
                return try await factory.downloader(for: type, task: task, delegate: delegate)
            } catch {
                LoggerProxy.DLog(tag: kLogTag, msg: "factory:\(factory) create downloader fail:\(error)")
            }
        }
        return nil
    }
}
