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
    @State var manager: DownloadManagerProtocol = CreateDownloadManager()
    @State var text: String = ""
    @State var userAgent: String = ""
    var body: some View {
        VStack {
            HStack {
                TextField("连接", text: $text)
                TextField("user-agent", text: $userAgent)
                Button("下载") {
                    if let url = URL(string: text),
                       let name = (text as? NSString)?.lastPathComponent {
                        let dest = FileManager.default.temporaryDirectory.appending(component: name)
                        Task {
                            var config = DownloadTaskConfiguration()
                            if userAgent.count > 0 {
                                config.headers["user-agent"] = userAgent
                                UserDefaults.standard.set(userAgent, forKey: "user-agent")
                            }
                            await manager.download(url: url, destination: dest, configuration: config)
                        }
                    }
                }
            }
            DownloadManagerView(manager: manager)
        }.onAppear(perform: {
            userAgent = UserDefaults.standard.string(forKey: "user-agent") ?? ""
        })
        .padding()
    }
}

// #Preview {
//    ContentView()
// }
