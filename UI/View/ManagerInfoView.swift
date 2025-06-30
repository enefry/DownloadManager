//
//  TaskCounterView.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/30.
//

import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

struct TaskCounterView: View {
    @ObservedObject var counter: DownloadTaskCounts
    var body: some View {
        TitleDetailLabel(title: "任务", detail: "\(counter.actives)/\(counter.all)")
    }
}

struct SpeedView: View {
    @ObservedObject var speedInfo: SpeedInfoModel

    var body: some View {
        HStack(spacing: 12) {
            TitleDetailLabel(title: "时间", detail: speedInfo.remainingTimeText)
                .frame(maxWidth: .infinity, alignment: .leading)
            TitleDetailLabel(title: "速度:", detail: speedInfo.speedText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundColor(.secondary)
    }
}

struct ProgressTextView: View {
    @ObservedObject var model: ProgressInfoModel
    var body: some View {
        TitleDetailLabel(title: "进度", detail: model.progressText)
    }
}

struct ManagerInfoView: View {
    @ObservedObject var model: GlobalManageModel
    @ObservedObject var counter: DownloadTaskCounts

    init(model: GlobalManageModel) {
        self.model = model
        counter = model.counter
    }

    var body: some View {
        VStack {
            HStack {
                TaskCounterView(counter: model.counter)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ProgressTextView(model: model.progress)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SpeedView(speedInfo: model.speed)
        }.padding()
    }
}
