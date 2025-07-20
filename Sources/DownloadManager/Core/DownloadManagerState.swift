//
//  DownloadManagerState.swift
//  DownloadManager
//
//  Created by chen on 2025/6/30.
//

import Atomics
import Combine
import ConcurrencyCollection
import DownloadManagerBasic
import Foundation
import LoggerProxy

private let kLogTag = "DM.St"

/// 下载管理器的公共状态，通过 Combine 发布，供 UI 或其他模块订阅
public final class DownloadManagerState: ObservableObject {
    /// 当前活跃（正在下载或准备下载）的任务数量
    @Published public private(set) var activeTaskCount: Int = 0
    /// 所有任务的列表，包括活跃、暂停、完成、失败等所有状态
    @Published public private(set) var allTasks: [DownloadTask] = []
    /// 最大并发下载数
    @Published public private(set) var maxConcurrentDownloads: Int = 4
    // 全局速度
    @Published public private(set) var speed: DownloadManagerSpeed = DownloadManagerSpeed(speed: 0, remainingTime: 0)
    /// 全局进度
    @Published public private(set) var progress: DownloadProgress = DownloadProgress(downloadedBytes: 0, totalBytes: 0)

    public private(set) var taskStateNotify = PassthroughSubject<(any DownloadTaskProtocol, TaskState), Never>()

    func sendNotify(taskState: (any DownloadTaskProtocol, TaskState)) async {
        await MainActor.run {
            taskStateNotify.send(taskState)
        }
    }

    /// 更新活跃任务数量
    /// - Parameter count: 新的活跃任务数量
    func updateActiveTaskCount(_ count: Int) {
        if activeTaskCount != count {
            activeTaskCount = count
        }
    }

    /// 更新所有任务列表
    /// - Parameter tasks: 新的任务列表
    func updateAllTasks(_ tasks: [DownloadTask]) {
        if allTasks != tasks {
            allTasks = tasks
        }
    }

    func update(speed: DownloadManagerSpeed) async {
        if speed != self.speed {
            self.speed = speed
        }
    }

    func update(progress: DownloadProgress) async {
        if progress != self.progress {
            self.progress = progress
        }
    }

    /// 更新最大并发下载数
    /// - Parameter count: 新的最大并发下载数
    func updateMaxConcurrentDownloads(_ count: Int) {
        if maxConcurrentDownloads != count {
            maxConcurrentDownloads = count
        }
    }
}
