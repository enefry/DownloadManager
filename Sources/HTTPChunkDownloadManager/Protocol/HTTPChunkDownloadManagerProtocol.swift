//
//  HTTPChunkDownloadManagerProtocol.swift
//  DownloadManager
//
//  Created by chen on 2025/6/20.
//

import Combine
import ConcurrencyCollection
import CryptoKit
import Foundation
import LoggerProxy

/**
 * 文件分片下载协议
 */
public protocol HTTPChunkDownloadManagerProtocol: Actor {
    /// 下载状态
    var state: ChunkDownloadState { get async }
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
