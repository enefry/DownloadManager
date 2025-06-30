//
//  TaskActionButtons.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/29.
//

import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

struct TaskActionButtons: View {
    // Using a lightweight observed object here to re-render buttons on state change
    @StateObject private var stateObserver: TaskStateObserver
    private let task: any DownloadTaskProtocol
    private let manager: any DownloadManagerProtocol

    init(task: any DownloadTaskProtocol, manager: any DownloadManagerProtocol) {
        self.task = task
        self.manager = manager
        _stateObserver = StateObject(wrappedValue: TaskStateObserver(task: task))
    }

    var body: some View {
        HStack {
            if stateObserver.state == .downloading {
                Button(action: { manager.pause(task: task) }) {
                    Image(systemName: "pause.fill")
                }
            }
            if stateObserver.state == .paused {
                Button(action: { manager.resume(task: task) }) {
                    Image(systemName: "play.fill")
                }
            }
            if !stateObserver.state.isFinished {
                Button(action: { manager.cancel(task: task) }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .foregroundColor(.red)
            }
        }
        .buttonStyle(.plain)
    }
}
