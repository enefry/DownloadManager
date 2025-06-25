//
//  HTTPChunkDownloadManagerDelegate.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/22.
//

import Combine
import ConcurrencyCollection
import CryptoKit
import DownloadManagerBasic
import Foundation
import LoggerProxy

/// 下载代理
public protocol HTTPChunkDownloadManagerDelegate: AnyObject, Sendable {
    func HTTPChunkDownloadManager(_ manager: any HTTPChunkDownloadManagerProtocol, didCompleteWith task: HTTPChunkDownloadTaskProtocol) async
    func HTTPChunkDownloadManager(_ manager: any HTTPChunkDownloadManagerProtocol, task: HTTPChunkDownloadTaskProtocol, didUpdateProgress progress: DownloadProgress) async
    func HTTPChunkDownloadManager(_ manager: any HTTPChunkDownloadManagerProtocol, task: HTTPChunkDownloadTaskProtocol, didUpdateState state: ChunkDownloadState) async
    func HTTPChunkDownloadManager(_ manager: any HTTPChunkDownloadManagerProtocol, task: HTTPChunkDownloadTaskProtocol, didFailWithError error: Error) async
}
