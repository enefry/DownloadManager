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
    var body: some View {
        VStack {
            HStack {
                TextField("连接", text: $text)
                Button("下载") {
                    if let url = URL(string: text),
                       let name = (text as? NSString)?.lastPathComponent {
                        let dest = FileManager.default.temporaryDirectory.appending(component: name)
                        Task {
                            await manager.download(url: url, destination: dest, configuration: nil)
                        }
                    }
                }
            }
            DownloadManagerView(manager: manager)
        }
        .padding()
    }
}

// #Preview {
//    ContentView()
// }
