//
//  HTTPChunkDownloadConfiguration.swift
//  DownloadManager
//
//  Created by chen on 2025/6/22.
//

import Combine
import ConcurrencyCollection
import CryptoKit
import Foundation
import LoggerProxy

/// 分块下载配置
public struct HTTPChunkDownloadConfiguration: Sendable {
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
