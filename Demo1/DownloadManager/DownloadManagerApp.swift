//
//  FileManagerDemoApp.swift
//  FileManagerDemo
//
//  Created by chen on 2025/6/22.
//

import SwiftUI
import DownloadManager_HTTPDownloader

@main
struct DownloadManagerApp: App {
    init() {
        registerHTTPDownloader()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
