//
//  GlobalActionsView.swift
//  DownloadManagerDemo
//
//  Created by chen on 2025/6/30.
//

import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

struct GlobalActionsView: View {
    var model: GlobalManageModel
    @ObservedObject var counter: DownloadTaskCounts
    @State var action: ActionBlock = ActionBlock()
    init(model: GlobalManageModel) {
        self.model = model
        counter = model.counter
        action = action
    }

    var body: some View {
        HStack {
            Button(action: model.pauseAll
                //                        {action = ActionBlock(show: true, type: .pause, title: "暂停所有", message: "暂停所有任务？", action: viewModel.pauseAll)}
                , label: {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 28))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                })
                .buttonStyle(.borderedProminent)
                .disabled(model.counter.actives == 0)

            Button(action: model.resumeAll
                //                        {action = ActionBlock(show: true, type: .resume, title: "恢复所有", message: "恢复所有下载？", action: )}
                , label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 28))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                })
                .buttonStyle(.borderedProminent)
                .disabled(model.counter.pause == 0)

            Button(action: {
                action = ActionBlock(show: true, type: .cancel, title: "停止所有", message: "停止所有下载？", action: model.manager.cancelAll)
            }, label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 28))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
            })
            .buttonStyle(.borderedProminent)
            .disabled(model.counter.actives == 0)

            Button(action: model.removeAllFinished
                //                       {action = ActionBlock(show: true, type: .cancel, title: "移除完成", destructive: true, message: "移除所有已经完成的任务？", action: viewModel.manager.removeAllFinished)}
                , label: {
                    Image(systemName: "clear.fill")
                        .font(.system(size: 28))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .foregroundColor(.red)
                })
                .buttonStyle(.borderedProminent)
                .disabled(model.counter.finished == 0)

            Button(action: {
                action = ActionBlock(show: true, type: .remove, title: "删除所有", message: "删除所有下载任务（包括未完成的的临时文件）？", action: model.removeAll)
            }, label: {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 28))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .foregroundColor(.red)
            })
            .buttonStyle(.borderedProminent)
            .disabled(model.counter.all == 0)
        }
        .alert(action.title, isPresented: $action.show, actions: {
            Button(
                role: .cancel,
                action: {
                    withAnimation {
                        action.show = false
                    }
                }
            ) {
                Text("取消")
            }
            Button(
                role: action.destructive ? .destructive : nil,
                action: {
                    withAnimation {
                        action.show = true
                        action.action()
                    }
                }
            ) {
                Text("确定")
            }

        }, message: {
            VStack {
                Text(action.message)
                    .font(.body)
                    .padding()
            }
        })
    }
}
