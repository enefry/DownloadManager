//
//  ActionBlock.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/29.
//

import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

/// 操作动作类型
enum ActionType {
    case none, pause, resume, cancel, remove, removeFinish
}

/// 操作动作及信息
struct ActionBlock {
    var show: Bool = false
    var type: ActionType = .none
    var title: String = ""
    var destructive: Bool = false
    var message: String = ""
    var action: @MainActor () -> Void = {}
}
