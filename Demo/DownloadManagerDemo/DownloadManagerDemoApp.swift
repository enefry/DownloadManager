//
//  DownloadManagerDemoApp.swift
//  DownloadManagerDemo
//
//  Created by chen on 2025/6/25.
//

import SwiftUI
import DownloadManager_HTTPDownloader

@main
struct DownloadManagerDemoApp: App {
    init() {
        registerHTTPDownloader()
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
