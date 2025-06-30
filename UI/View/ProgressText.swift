//
//  ProgressText.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/29.
//

import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

struct ProgressText: View {
    @ObservedObject var model: ProgressInfoModel
    var body: some View {
        Text(model.progressText)
    }
}

struct SpeedText: View {
    @ObservedObject var model: SpeedInfoModel
    var body: some View {
        Text(model.speedText)
    }
}
