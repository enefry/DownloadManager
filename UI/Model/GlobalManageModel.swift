//
//  GlobalManageModel.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/30.
//
import Combine
import DownloadManager
import SwiftUI

/// 全局管理，包含信息+进度+操作
class GlobalManageModel: ObservableObject {
    let manager: any DownloadManagerProtocol

    var counter: DownloadTaskCounts // 各种类型任务的数量
    var progress: ProgressInfoModel // 总下载进度
    var speed: SpeedInfoModel // 总下载速度

    private var cancellables: [AnyCancellable] = []

    init(manager: any DownloadManagerProtocol) {
        self.manager = manager
        progress = ProgressInfoModel(progressPublisher: manager.progressPublisher)
        speed = SpeedInfoModel(speedPublisher: manager.speedPublisher)
        counter = DownloadTaskCounts()

        // 监听任务数量和任务变化，更新类型任务数量
        manager.allTasksPublisher
            .combineLatest(manager.activeTaskCountPublisher)
            .throttle(for: 0.1, scheduler: RunLoop.main, latest: true)
            .sink(receiveValue: { [weak self] tasks, count in
                Task {
                    await self?.update(tasks, activeCount: count)
                }
            })
            .store(in: &cancellables)
    }

    @MainActor
    func update(_ tasks: [any DownloadTaskProtocol], activeCount: Int) {
        let pause = tasks.reduce(0, { $0 + (($1.state == .paused) ? 1 : 0) })
        let finished = tasks.reduce(0, { $0 + (($1.state.isFinished) ? 1 : 0) })
        let newCount = DownloadTaskCounts(all: tasks.count, actives: activeCount, pause: pause, finished: finished)
        if newCount != counter {
            counter.update(counter: newCount)
        }
    }

    func pauseAll() {
        manager.pauseAll()
    }

    func resumeAll() {
        manager.resumeAll()
    }

    func removeAllFinished() {
        manager.removeAllFinished()
    }

    func removeAll() {
        manager.removeAll()
    }
}
