//
//  GlobalActionModel.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/29.
//
import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

/// 下载数量统计
class DownloadTaskCounts: ObservableObject, Equatable {
    @Published var all: Int = 0
    @Published var actives: Int = 0
    @Published var pause: Int = 0
    @Published var finished: Int = 0
    init(all: Int = 0, actives: Int = 0, pause: Int = 0, finished: Int = 0) {
        self.all = all
        self.actives = actives
        self.pause = pause
        self.finished = finished
    }

    func update(counter: DownloadTaskCounts) {
        all = counter.all
        actives = counter.actives
        pause = counter.pause
        finished = counter.finished
    }

    static func == (lhs: DownloadTaskCounts, rhs: DownloadTaskCounts) -> Bool {
        return lhs.all == rhs.all
            && lhs.actives == rhs.actives
            && lhs.pause == rhs.pause
            && lhs.finished == rhs.finished
    }
}
