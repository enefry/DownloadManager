//
//  GlobalActionsView.swift
//  DownloadManager
//
//  Created by chen on 2025/6/29.
//

import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

struct ManagerView: View {
    var model: GlobalManageModel
    @ObservedObject var counter: DownloadTaskCounts

    init(model: GlobalManageModel) {
        self.model = model
        self.counter = model.counter
    }

    var body: some View {
        VStack {
            ManagerInfoView(model: model)
            GlobalActionsView(model: model)
        }
    }
}
