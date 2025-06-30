//
//  TaskListView.swift
//  DownloadManager
//
//  Created by chen on 2025/6/29.
//

import SwiftUI

struct TaskListView: View {
    @ObservedObject var model: DownloadTasListModel

    var body: some View {
        FilterButtonsView(selectedFilter: $model.selectedFilter)
        Divider()
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.filteredTasks, id: \.identifier) { task in
                    TaskRowView(task: task, manager: model.manager)
                    Divider()
                }
            }
        }
    }
}
