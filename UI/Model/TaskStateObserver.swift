//
//  TaskStateObserver.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/29.
//


import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

/// A lightweight observable object to drive UI updates for task state changes.
@MainActor
class TaskStateObserver: ObservableObject {
    @Published var state: TaskState
    private var cancellables = Set<AnyCancellable>()

    init(task: any DownloadTaskProtocol) {
        state = task.state
        task.statePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: \.state, on: self)
            .store(in: &cancellables)
    }
}
