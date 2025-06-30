//
//  DownloadTasListModel.swift
//  DownloadManager
//
//  Created by chen on 2025/6/29.
//
import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

class DownloadTasListModel: ObservableObject {
    let manager: any DownloadManagerProtocol
    @Published var selectedFilter: DownloadStateFilter = .all
    @Published var tasks: [any DownloadTaskProtocol] = []

    private var cancellables = Set<AnyCancellable>()

    init(manager: any DownloadManagerProtocol) {
        self.manager = manager
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
        var existsTasks = Set(self.tasks.map({ $0.identifier }))
        var newTasks = Set(tasks.map({ $0.identifier }))
        if existsTasks != newTasks {
            self.tasks = tasks
        }
    }

    var filteredTasks: [any DownloadTaskProtocol] {
        switch selectedFilter {
        case .all:
            return tasks
        case .downloading:
            return tasks.filter { $0.state == .downloading }
        case .paused:
            return tasks.filter { $0.state == .paused }
        case .completed:
            return tasks.filter { $0.state == .completed }
        }
    }
}
