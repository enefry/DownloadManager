//
//  DownloadManagerUI.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/22.
//

import Combine
import DownloadManager
import SwiftUI

@MainActor
class DownloadManagerViewModel: ObservableObject {
    let manager: any DownloadManagerProtocol
    @Published var tasks: [any DownloadTaskProtocol] = []
    @Published var activeTaskCount: Int = 0
    @Published var selectedFilter: DownloadStateFilter = .all

    private var cancellables = Set<AnyCancellable>()

    init(manager: any DownloadManagerProtocol) {
        self.manager = manager
        setupBindings()
    }

    private func setupBindings() {
        if let concreteManager = manager as? DownloadManager {
            concreteManager.state.$allTasks
                .map { $0 as [any DownloadTaskProtocol] }
                .receive(on: DispatchQueue.main)
                .assign(to: \.tasks, on: self)
                .store(in: &cancellables)

            concreteManager.state.$activeTaskCount
                .receive(on: DispatchQueue.main)
                .assign(to: \.activeTaskCount, on: self)
                .store(in: &cancellables)
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

enum DownloadStateFilter: String, CaseIterable {
    case all = "全部"
    case downloading = "下载中"
    case paused = "已暂停"
    case completed = "已完成"
}

public struct DownloadManagerView: View {
    @StateObject private var viewModel: DownloadManagerViewModel

    public init(manager: any DownloadManagerProtocol) {
        _viewModel = StateObject(wrappedValue: DownloadManagerViewModel(manager: manager))
    }

    public var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif
        VStack(spacing: 0) {
            GlobalActionsView(viewModel: viewModel)
            FilterButtonsView(selectedFilter: $viewModel.selectedFilter)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredTasks, id: \.identifier) { task in
                        TaskRowView(task: task, manager: viewModel.manager)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
        }
        .navigationTitle("下载管理器")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Subviews

private struct GlobalActionsView: View {
    @ObservedObject var viewModel: DownloadManagerViewModel

    var body: some View {
        HStack {
            Text("下载中: \(viewModel.activeTaskCount)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Button("全部暂停", action: viewModel.pauseAll)
            Button("全部恢复", action: viewModel.resumeAll)
            Button("清除已完成", action: viewModel.removeAllFinished)
                .foregroundColor(.red)
            Button("删除所有", action: viewModel.removeAll)
        }
        .padding()
    }
}

private struct FilterButtonsView: View {
    @Binding var selectedFilter: DownloadStateFilter

    var body: some View {
        Picker("Filter", selection: $selectedFilter) {
            ForEach(DownloadStateFilter.cases, id: \.self) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.bottom, 10)
    }
}

private struct TaskRowView: View {
    @ObservedObject private var taskViewModel: DownloadTaskViewModel

    private let manager: any DownloadManagerProtocol

    init(task: any DownloadTaskProtocol, manager: any DownloadManagerProtocol) {
        _taskViewModel = ObservedObject(wrappedValue: DownloadTaskViewModel(task: task, mgr: manager))
        self.manager = manager
    }

    var body: some View {
        #if DEBUG
            let _ = Self._printChanges()
        #endif
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

            ProgressBar(progress: taskViewModel.progresObj)
                .frame(height: 8)

            HStack {
                ProgressText(progress: taskViewModel.progresObj)
                Spacer()
                SpeedText(progress: taskViewModel.progresObj)
                Spacer()
                TaskActionButtons(task: taskViewModel.task, manager: manager)
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }.contextMenu {
            Button("删除", action: taskViewModel.onActionDelete)
            Button("暂停", action: taskViewModel.onActionPause)
            Button("恢复", action: taskViewModel.onActionResume)
            Button("重新下载", action: taskViewModel.onActionRestart)
        }
    }
}

struct ProgressText: View {
    @ObservedObject var progress: DownloadTaskViewModel.ProgressObject
    var body: some View {
        Text(progress.progressText)
    }
}

struct SpeedText: View {
    @ObservedObject var progress: DownloadTaskViewModel.ProgressObject
    var body: some View {
        Text(progress.speedText)
    }
}

@MainActor
class DownloadTaskViewModel: ObservableObject {
    let mgr: any DownloadManagerProtocol
    let task: any DownloadTaskProtocol

    class ProgressObject: ObservableObject {
        let task: any DownloadTaskProtocol
        @Published var progress: Double = 0
        @Published var speedText: String = ""
//        @Published var speed: Double = 0
        @Published var progressText: String = ""
        private var cancellables = Set<AnyCancellable>()

        init(task: any DownloadTaskProtocol) {
            self.task = task

            task.progressPublisher
                .receive(on: DispatchQueue.main)
                .map {
                    let downloaded = ByteCountFormatter.string(fromByteCount: $0.downloadedBytes, countStyle: .file)
                    let total = ByteCountFormatter.string(fromByteCount: $0.totalBytes, countStyle: .file)
                    return $0.totalBytes > 0 ? "\(downloaded) / \(total)" : downloaded
                }
                .assign(to: \.progressText, on: self)
                .store(in: &cancellables)

            task.progressPublisher
                .receive(on: DispatchQueue.main)
                .map { Double($0.downloadedBytes) / Double($0.totalBytes > 0 ? $0.totalBytes : 1) }
                .assign(to: \.progress, on: self)
                .store(in: &cancellables)

            if let concreteTask = task as? DownloadTask {
                concreteTask.speedPublisher
                    .receive(on: DispatchQueue.main)
                    .map({"\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))/s"})
                    .assign(to: \.speedText, on: self)
                    .store(in: &cancellables)
            }
        }
    }

    var progresObj: ProgressObject
    @Published var state: TaskState

    private var cancellables = Set<AnyCancellable>()

    init(task: any DownloadTaskProtocol, mgr: any DownloadManagerProtocol) {
        self.mgr = mgr
        self.task = task
        progresObj = ProgressObject(task: task)
        state = task.state
        progresObj.progress = Double(task.downloadedBytes) / Double(task.totalBytes > 0 ? task.totalBytes : 1)

        // Binding for mock tasks used in previews

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

private struct TaskActionButtons: View {
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

/// A lightweight observable object to drive UI updates for task state changes.
@MainActor
private class TaskStateObserver: ObservableObject {
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

private struct ProgressBar: View {
    @ObservedObject var progress: DownloadTaskViewModel.ProgressObject

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(0.3)
                    .foregroundColor(.gray)

                Rectangle().frame(width: min(CGFloat(progress.progress) * geometry.size.width, geometry.size.width), height: geometry.size.height)
                    .foregroundColor(Color.accentColor)
                    .animation(.linear, value: progress.progress)
            }
            .cornerRadius(4.0)
        }
    }
}

extension DownloadStateFilter {
    static var cases: [DownloadStateFilter] {
        return allCases
    }
}
