//
//  ProgressObject.swift
//  DownloadManager
//
//  Created by chen on 2025/6/29.
//

import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

/// 监听并发布修改进度 （根据下载速度变化）
class ProgressInfoModel: ObservableObject {
    @Published var progress: Double = 0
    @Published var progressText: String = ""
    //    @Published var speedText: String = ""
//    @Published var remainingTimeText: String = ""
    private var cancellables = Set<AnyCancellable>()

    init(progressPublisher: AnyPublisher<DownloadProgress, Never>) {
        progressPublisher
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [weak self] progress in
                guard let self = self else {
                    return
                }
                let downloaded = ByteCountFormatter.string(fromByteCount: progress.downloadedBytes, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
                if progress.totalBytes > 0 {
                    self.progress = Double(progress.downloadedBytes) / Double(progress.totalBytes)
                    self.progressText = "\(downloaded)/\(total)"
                } else {
                    self.progress = 0
                    self.progressText = "\(downloaded)/-"
                }
            })
            .store(in: &cancellables)
    }
}

/// 监听并发布修改速度 正常是定时
class SpeedInfoModel: ObservableObject {
    @Published var speedText: String = ""
    @Published var remainingTimeText: String = ""
    private var cancellables = Set<AnyCancellable>()

    init(speedPublisher: AnyPublisher<DownloadManagerSpeed, Never>) {
        speedPublisher
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [weak self] speed in
                guard let self = self else {
                    return
                }
                self.speedText = "\(ByteCountFormatter.string(fromByteCount: Int64(speed.speed), countStyle: .file))/s"
                self.remainingTimeText = format(time: speed.remainingTime)
            })
            .store(in: &cancellables)
    }
}
