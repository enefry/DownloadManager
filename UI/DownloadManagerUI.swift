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
    struct Counts: Equatable, Hashable {
        var all: Int = 0
        var actives: Int = 0
        var pause: Int = 0
        var finished: Int = 0
    }

    let manager: any DownloadManagerProtocol
    var tasks: [any DownloadTaskProtocol] = []
    @Published var counter: Counts = Counts()
    @Published var selectedFilter: DownloadStateFilter = .all

    private var cancellables = Set<AnyCancellable>()

    init(manager: any DownloadManagerProtocol) {
        self.manager = manager
        setupBindings()
    }

    private func setupBindings() {
        if let concreteManager = manager as? DownloadManager {
            concreteManager.state.$allTasks
                .combineLatest(concreteManager.state.$activeTaskCount)
                .throttle(for: 0.1, scheduler: RunLoop.main, latest: true)
                .sink(receiveValue: { [weak self] tasks, count in
                    self?.update(tasks, activeCount: count)
                })
                .store(in: &cancellables)
        }
    }

    @MainActor
    func update(_ tasks: [any DownloadTaskProtocol], activeCount: Int) {
        let pause = tasks.reduce(0, { $0 + (($1.state == .paused) ? 1 : 0) })
        let finished = tasks.reduce(0, { $0 + (($1.state.isFinished) ? 1 : 0) })
        var existsTasks = Set(self.tasks.map({ $0.identifier }))
        var newTasks = Set(tasks.map({ $0.identifier }))
        if existsTasks != newTasks {
            self.tasks = tasks
        }
        let newCount = Counts(all: tasks.count, actives: activeCount, pause: pause, finished: finished)
        if newCount != counter {
            counter = newCount
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
//            let _ = Self._printChanges()
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

private enum ActionType {
    case none, pause, resume, cancel, remove, removeFinish
}

private struct ActionBlock {
    var show: Bool = false
    var type: ActionType = .none
    var title: String = ""
    var destructive: Bool = false
    var message: String = ""
    var action: @MainActor () -> Void = {}
}

// MARK: - Subviews

private struct GlobalActionsView: View {
    @ObservedObject var viewModel: DownloadManagerViewModel
    @State var action = ActionBlock()

    var body: some View {
        HStack {
            Text("下载中: \(viewModel.counter.actives)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            HStack {
                Button(action: {
                    action = ActionBlock(show: true, type: .pause, title: "暂停所有", message: "暂停所有任务？", action: viewModel.pauseAll)
                }, label: {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 32))
                        .frame(width: 40, height: 40)
                })
                .disabled(viewModel.counter.actives == 0)

                Button(action: {
                    action = ActionBlock(show: true, type: .resume, title: "恢复所有", message: "恢复所有下载？", action: viewModel.resumeAll)
                }, label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 32))
                        .frame(width: 40, height: 40)
                })
                .disabled(viewModel.counter.pause == 0)

                Button(action: {
                    action = ActionBlock(show: true, type: .cancel, title: "停止所有", message: "停止所有下载？", action: viewModel.manager.cancelAll)
                }, label: {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 32))
                        .frame(width: 40, height: 40)
                })
                .disabled(viewModel.counter.actives == 0)

                Button(action: {
                    action = ActionBlock(show: true, type: .cancel, title: "移除完成", destructive: true, message: "移除所有已经完成的任务？", action: viewModel.manager.removeAllFinished)
                }, label: {
                    Image(systemName: "clear.fill")
                        .font(.system(size: 32))
                        .frame(width: 40, height: 40)
                        .foregroundColor(.red)
                })
                .disabled(viewModel.counter.finished == 0)

                Button(action: {
                    action = ActionBlock(show: true, type: .remove, title: "删除所有", message: "删除所有下载任务（包括未完成的的临时文件）？", action: viewModel.removeAll)
                }, label: {
                    Image(systemName: "trash.circle.fill")
                        .font(.system(size: 32))
                        .frame(width: 40, height: 40)
                        .foregroundColor(.red)
                })
                .disabled(viewModel.counter.all == 0)
            }.opacity(viewModel.counter.all > 0 ? 1 : 0)
        }
        .alert(action.title, isPresented: $action.show, actions: {
            Button(
                role: .cancel,
                action: {
                    withAnimation {
                        action.show = false
                    }
                }
            ) {
                Text("取消")
            }
            Button(
                role: action.destructive ? .destructive : nil,
                action: {
                    withAnimation {
                        action.show = true
                        action.action()
                    }
                }
            ) {
                Text("确定")
            }

        }, message: {
            VStack {
                Text(action.message)
                    .font(.body)
                    .padding()
            }
        })
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
//            _ = Self._printChanges()
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
                    .map({ "\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))/s" })
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

// struct ActionConfirmView: View {
//    @Binding var isPresented: Bool
//    let title: String
//    let message: String
//    let comfirmTitle: String
//    let cancelTitle: String
//    let action: () -> Void
//
//    var body: some View {
//        VStack(spacing: 0) {
//            // 标题栏
//            HStack {
//                Button(cancelTitle) {
//                    isPresented.toggle()
//                }
//                .foregroundColor(.secondary)
//                .font(.body)
//
//                Spacer()
//
//                Text(title)
//                    .font(.headline)
//                    .fontWeight(.semibold)
//                    .foregroundColor(.primary)
//
//                Spacer()
//
//                Button(comfirmTitle) {
//                    isPresented.toggle()
//                    action()
//                }
//                .foregroundColor(validationResult.isInvalid() ? .secondary : .accentColor)
//                .font(.body)
//                .fontWeight(.medium)
//                .disabled(validationResult.isInvalid())
//            }
//            .padding(.horizontal, 20)
//            .padding(.vertical, 16)
//            .background(Color.systemBackground)
//
//            Divider()
//
//            // 输入区域
//            VStack(alignment: .leading, spacing: 12) {
//                TextField(placeholder, text: $fileName)
//                    .textFieldStyle(RoundedBorderTextFieldStyle())
//                    .focused($isTextFieldFocused)
//                    .onSubmit {
//                        if !validationResult.isInvalid() {
//                            action(fileName.trimmingCharacters(in: .whitespacesAndNewlines), true)
//                        }
//                    }
//
//                    .onChange(of: fileName) { _, newValue in
//                        validateInput(newValue)
//                    }
//
//                // 验证提示信息
//                if case let .invalid(message) = validationResult {
//                    HStack {
//                        Image(systemName: "exclamationmark.triangle.fill")
//                            .foregroundColor(.red)
//                            .font(.caption)
//                        Text(message)
//                            .font(.caption)
//                            .foregroundColor(.red)
//                    }
//                    .transition(.opacity.combined(with: .move(edge: .top)))
//                } else if case let .warning(message) = validationResult {
//                    HStack {
//                        Image(systemName: "exclamationmark.triangle.fill")
//                            .foregroundColor(.orange)
//                            .font(.caption)
//                        Text(message)
//                            .font(.caption)
//                            .foregroundColor(.orange)
//                    }
//                    .transition(.opacity.combined(with: .move(edge: .top)))
//                }
//            }
//            .padding(.horizontal, 20)
//            .padding(.vertical, 20)
//            .background(Color.systemBackground)
//        }
//        .background(Color.systemBackground)
//        .cornerRadius(14)
//        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 4)
//        .frame(maxWidth: 320)
//        .onAppear {
//            isTextFieldFocused = true
//            validateInput(fileName)
//        }
//        .animation(.easeInOut(duration: 0.2), value: validationResult)
//    }
// }
//
//// 使用修饰符的版本
// struct ActionComfirmDialog: ViewModifier {
//    @Binding var isPresented: Bool
//    let title: String
//    let message: String
//    let comfirmTitle: String
//    let cancelTitle: String
//    let action: () -> Void
//
//    func body(content: Content) -> some View {
//        content
//            .overlay(
//                ZStack {
//                    if isPresented {
//                        Color.black.opacity(0.3)
//                            .ignoresSafeArea()
//                            .onTapGesture {
//                                isPresented = false
//                                action()
//                            }
//
//                        FileNameInputView(
//                            title: title,
//                            fileName: fileName,
//                            placeholder: placeholder,
//                            saveTitle: saveTitle,
//                            cancelTitle: cancelTitle,
//                            validator: validator
//                        ) { name, confirmed in
//                            isPresented = false
//                            action(name, confirmed)
//                        }
//                        .transition(.scale.combined(with: .opacity))
//                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isPresented)
//                    }
//                }
//            )
//    }
// }
