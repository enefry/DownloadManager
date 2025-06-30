//
//  DownloadTaskViewModel.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/29.
//

import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

@MainActor
class DownloadTaskViewModel: ObservableObject {
    let mgr: any DownloadManagerProtocol
    let task: any DownloadTaskProtocol
    var progress: ProgressInfoModel
    var speed: SpeedInfoModel
    @Published var state: TaskState

    private var cancellables = Set<AnyCancellable>()

    init(task: any DownloadTaskProtocol, mgr: any DownloadManagerProtocol) {
        self.mgr = mgr
        self.task = task
        progress = ProgressInfoModel(progressPublisher: task.progressPublisher)
        speed = SpeedInfoModel(speedPublisher: task.speedPublisher)
        state = task.state
        // Binding for real tasks
        task.statePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: \.state, on: self)
            .store(in: &cancellables)
    }

    func onActionDelete() {
        Task {
            await mgr.remove(task: task)
        }
    }

    func onActionPause() {
        Task {
            await mgr.pause(task: task)
        }
    }

    func onActionResume() {
        Task {
            await mgr.resume(task: task)
        }
    }

    func onActionRestart() {
        Task {
            await mgr.restart(task: task)
        }
    }
}
