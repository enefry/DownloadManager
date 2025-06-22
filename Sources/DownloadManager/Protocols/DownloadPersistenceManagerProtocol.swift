//
//  DownloadPersistenceManagerProtocol.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/21.
//

import Foundation

public protocol DownloadPersistenceManagerProtocol {
    func setup(configure: DownloadManagerConfiguration) async
    func saveTasks(_ tasks: [DownloadTask]) async throws
    func loadTasks() async throws -> [DownloadTask]
    func clearTasks() async throws
}
