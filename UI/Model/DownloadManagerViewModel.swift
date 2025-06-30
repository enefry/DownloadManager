//
//  DownloadManagerViewModel.swift
//  DownloadManager
//
//  Created by chen on 2025/6/29.
//

import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

/// 下载列表筛选器
enum DownloadStateFilter: String, CaseIterable {
    case all = "全部"
    case downloading = "下载中"
    case paused = "已暂停"
    case completed = "已完成"
}

/// 所有下载筛选器
extension DownloadStateFilter {
    static var cases: [DownloadStateFilter] {
        return allCases
    }
}

/// 下载管理关联 model ,这个变动会导致全部都刷新，不随便@Publish
@MainActor
class DownloadManagerViewModel: ObservableObject {
    let manager: any DownloadManagerProtocol
    var managerModel: GlobalManageModel
    var listModel: DownloadTasListModel

    private var cancellables = Set<AnyCancellable>()

    init(_ manager: any DownloadManagerProtocol) {
        self.manager = manager
        managerModel = GlobalManageModel(manager: manager)
        listModel = DownloadTasListModel(manager: manager)
    }
}
