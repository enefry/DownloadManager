//
//  ContentView.swift
//  FileManagerDemo
//
//  Created by 陈任伟 on 2025/6/22.
//

import DownloadManager
import DownloadManager_HTTPDownloader
import DownloadManagerUI
import SwiftUI

struct ContentView: View {
    @FocusState var connectFocos: Bool
    @FocusState var uaFocos: Bool

    @State var manager: DownloadManagerProtocol = CreateDownloadManager()
    @State var text: String = ""
    @State var userAgent: String = ""
    var body: some View {
        VStack {
            HStack {
                VStack {
                    TextField("连接", text: $text)
                        .focused($connectFocos)
                    TextField("user-agent", text: $userAgent)
                        .focused($uaFocos)
                }
                Button("下载") {
                    connectFocos = false
                    uaFocos = false
                    if let url = URL(string: text),
                       let name = (text as? NSString)?.lastPathComponent {
                        let dest = FileManager.default.temporaryDirectory.appending(component: name)
                        Task {
                            var config = DownloadTaskConfiguration()
                            if userAgent.count > 0 {
                                config.headers["user-agent"] = userAgent
                                UserDefaults.standard.set(userAgent, forKey: "user-agent")
                            }
                            config.chunkSize = 64 * 1024 * 1024
                            config.maxConcurrentChunks = 1
                            _ = await manager.download(url: url, destination: dest, configuration: config)
                        }
                    }
                }
            }
            DownloadManagerView(manager: manager)
                .scrollDismissesKeyboard(.automatic)
        }.onAppear(perform: {
            userAgent = UserDefaults.standard.string(forKey: "user-agent") ?? ""
        })
        .padding()
    }
}
