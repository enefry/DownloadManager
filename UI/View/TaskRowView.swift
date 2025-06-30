//
//  TaskRowView.swift
//  DownloadManager
//
//  Created by chen on 2025/6/29.
//

import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

/// 每一行的任务的View
struct TaskRowView: View {
    @ObservedObject private var taskViewModel: DownloadTaskViewModel

    private let manager: any DownloadManagerProtocol

    init(task: any DownloadTaskProtocol, manager: any DownloadManagerProtocol) {
        _taskViewModel = ObservedObject(wrappedValue: DownloadTaskViewModel(task: task, mgr: manager))
        self.manager = manager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(taskViewModel.task.destinationURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(taskViewModel.state.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ProgressBar(progress: taskViewModel.progress)
                .frame(height: 8)

            HStack {
                ProgressText(model: taskViewModel.progress)
                Spacer()
                SpeedText(model: taskViewModel.speed)
                Spacer()
                TaskActionButtons(task: taskViewModel.task, manager: manager)
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle()) // 指定响应区域
        .contextMenu {
            Button("删除", action: taskViewModel.onActionDelete)
            Button("暂停", action: taskViewModel.onActionPause)
            Button("恢复", action: taskViewModel.onActionResume)
            Button("重新下载", action: taskViewModel.onActionRestart)
        }
    }
}
