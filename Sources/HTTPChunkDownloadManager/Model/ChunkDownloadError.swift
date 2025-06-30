//
//  HTTPChunkDownloadError.swift
//  DownloadManager
//
//  Created by chen on 2025/6/22.
//

import Combine
import ConcurrencyCollection
import CryptoKit
import DownloadManagerBasic
import Foundation
import LoggerProxy

/// 分块下载错误
public extension DownloadError {
    static func corruptedChunk(_ identifier: String) -> DownloadError {
        return .init(code: -100, description: "分块下载异常:\(identifier)")
    }
}
