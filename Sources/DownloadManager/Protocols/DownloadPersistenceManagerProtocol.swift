//
//  DownloadPersistenceManagerProtocol.swift
//  DownloadManager
//
//  Created by chen on 2025/6/23.
//

import Combine
import Foundation

/// 持久化下载队列
public protocol DownloadPersistenceManagerProtocol: Sendable {
    func setup(configure: DownloadManagerConfiguration) async
    func saveTasks(_ tasks: [DownloadTask]) async throws
    func loadTasks() async throws -> [DownloadTask]
    func clearTasks() async throws
}
