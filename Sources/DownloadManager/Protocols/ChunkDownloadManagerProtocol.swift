//
//  ChunkDownloadManagerProtocol.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/20.
//

import Combine
import ConcurrencyCollection
import CryptoKit
import Foundation
import LoggerProxy

/// 下载代理
public protocol ChunkDownloadManagerDelegate: AnyObject, Sendable {
    func chunkDownloadManager(_ manager: any ChunkDownloadManagerProtocol, didCompleteWith task: DownloadTask)
    func chunkDownloadManager(_ manager: any ChunkDownloadManagerProtocol, task: DownloadTask, didUpdateProgress progress: DownloadProgress)
    func chunkDownloadManager(_ manager: any ChunkDownloadManagerProtocol, task: DownloadTask, didUpdateState state: DownloadState)
    func chunkDownloadManager(_ manager: any ChunkDownloadManagerProtocol, task: DownloadTask, didFailWithError error: Error)
}

/// 分块下载配置
public struct ChunkConfiguration: Sendable {
    public let chunkSize: Int64
    public let maxConcurrentChunks: Int
    public let progressUpdateInterval: TimeInterval
    public let bufferSize: Int

    public init(chunkSize: Int64, maxConcurrentChunks: Int, progressUpdateInterval: TimeInterval = 0.1, bufferSize: Int = 16 * 1024) {
        self.chunkSize = chunkSize
        self.maxConcurrentChunks = maxConcurrentChunks
        self.progressUpdateInterval = progressUpdateInterval
        self.bufferSize = bufferSize
    }
}

/// 分块下载错误
public enum ChunkDownloadError: Error, LocalizedError, Sendable {
    case networkError(String)
    case fileSystemError(String)
    case serverNotSupported
    case insufficientDiskSpace
    case corruptedChunk(String)
    case invalidResponse
    case timeout
    case cancelled
    case unknown(Error)

    public var errorDescription: String? {
        switch self {
        case let .networkError(message):
            return "网络错误: \(message)"
        case let .fileSystemError(message):
            return "文件系统错误: \(message)"
        case .serverNotSupported:
            return "服务器不支持分片下载或无法获取文件大小"
        case .insufficientDiskSpace:
            return "磁盘空间不足"
        case let .corruptedChunk(index):
            return "分片 \(index) 损坏或不完整"
        case .invalidResponse:
            return "服务器返回无效响应"
        case .timeout:
            return "下载超时"
        case .cancelled:
            return "下载已取消"
        case let .unknown(error):
            return "未知错误: \(error.localizedDescription)"
        }
    }

    public var errorCode: Int {
        switch self {
        case .networkError: return 0x2001
        case .fileSystemError: return 0x2002
        case .serverNotSupported: return 0x2003
        case .insufficientDiskSpace: return 0x2004
        case .corruptedChunk: return 0x2005
        case .invalidResponse: return 0x2006
        case .timeout: return 0x2007
        case .cancelled: return 0x2008
        case .unknown: return 0x20FF
        }
    }
}

/**
 * 文件分片下载协议
 */
public protocol ChunkDownloadManagerProtocol: Actor {
    /// 下载状态
    var state: DownloadState { get async }
    /// 是否支持分片下载
    var chunkAvailable: Bool { get async }
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
