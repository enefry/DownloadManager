//
//  DownloadProgress.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/22.
//

import Combine
import Foundation

/// 下载进度数据类
public struct DownloadProgress: CustomStringConvertible, Codable, Sendable, Hashable, Equatable {
    /// 进度描述
    public var description: String {
        if totalBytes > 0 {
            return "\(downloadedBytes.dm_formatBytes())/\(totalBytes.dm_formatBytes())[\(String(format: "%.2f", downloadedBytes / totalBytes))]"
        } else {
            return "\(downloadedBytes)/0 [~]"
        }
    }

    /// 记录时间
    public let timestamp: TimeInterval
    /// 已经下载大小
    public let downloadedBytes: Int64
    /// 总大小，对于未知下子大小，这个值为-1
    public let totalBytes: Int64
    /// 初始化
    public init(timestamp: TimeInterval = Date.now.timeIntervalSince1970, downloadedBytes: Int64, totalBytes: Int64) {
        self.timestamp = timestamp
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
    }
}
