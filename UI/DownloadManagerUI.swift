//
//  DownloadManagerUI.swift
//  DownloadManager
//
//  Created by chen on 2025/6/22.
//

import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

// MARK: - Subviews

public struct DownloadManagerView: View {
    @StateObject private var model: DownloadManagerViewModel

    public init(manager: any DownloadManagerProtocol) {
        _model = StateObject(wrappedValue: DownloadManagerViewModel(manager))
    }

    public var body: some View {
        VStack(spacing: 8) {
            ManagerView(model: model.managerModel)
            TaskListView(model: model.listModel)
        }
        .navigationTitle("下载管理器")
        .onAppear(perform: {
            UIApplication.shared.isIdleTimerDisabled = true
        }).onDisappear(perform: {
            UIApplication.shared.isIdleTimerDisabled = false
        })
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
