//
//  ProgressBar.swift
//  DownloadManager
//
//  Created by chen on 2025/6/29.
//

import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

/// 进度条
struct ProgressBar: View {
    @ObservedObject var progress: ProgressInfoModel
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
