//
//  DownloadManager_HTTPDownloader.swift
//  DownloadManager
//
//  Created by chen on 2025/6/25.
//

import DownloadManager
import DownloadManagerBasic
import Foundation
import HTTPChunkDownloadManager

extension ChunkDownloadState {
    func toDownloaderState() -> DownloaderState {
        switch self {
        case .initialed:
            return .initial
        case .preparing:
            return .initial
        case .downloading:
            return .downloading
        case .paused:
            return .paused
        case .merging:
            return .downloading
        case .completed:
            return .completed
        case .cancelled:
            return .stop
        case let .failed(error):
            return .failed(error)
        }
    }
}

class HTTPChunkDownloadTask: HTTPChunkDownloadTaskProtocol {
    let task: any DownloadTaskProtocol
    var identifier: String {
        task.identifier
    }

    var url: URL {
        task.url
    }

    var destinationURL: URL {
        task.destinationURL
    }

    var downloadedBytes: Int64 {
        task.downloadedBytes
    }

    var totalBytes: Int64 {
        task.totalBytes
    }

    init(task: any DownloadTaskProtocol) {
        self.task = task
    }

    var urlSessionConfigure: URLSessionConfiguration {
        task.taskConfigure.urlSessionConfigure()
    }

    func request(for method: String, headers: [String: String]?) async throws -> URLRequest {
        var request = URLRequest(url: task.url)
        request.httpMethod = method

        for (key, value) in task.taskConfigure.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let timeoutInterval = task.taskConfigure.timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        return request
    }
}

public class DownloadManager_HTTPDownloader: Downloader, HTTPChunkDownloadManagerDelegate, @unchecked Sendable {
    public func HTTPChunkDownloadManager(_ manager: any HTTPChunkDownloadManagerProtocol, didCompleteWith task: any HTTPChunkDownloadTaskProtocol) async {
        await delegate?.downloader(self, didCompleteWith: self.task)
    }

    public func HTTPChunkDownloadManager(_ manager: any HTTPChunkDownloadManagerProtocol, task: any HTTPChunkDownloadTaskProtocol, didUpdateProgress progress: DownloadManagerBasic.DownloadProgress) async {
        await delegate?.downloader(self, task: self.task, didUpdateProgress: progress)
    }

    public func HTTPChunkDownloadManager(_ manager: any HTTPChunkDownloadManagerProtocol, task: any HTTPChunkDownloadTaskProtocol, didUpdateState state: ChunkDownloadState) async {
        await delegate?.downloader(self, task: self.task, didUpdateState: state.toDownloaderState())
    }

    public func HTTPChunkDownloadManager(_ manager: any HTTPChunkDownloadManagerProtocol, task: any HTTPChunkDownloadTaskProtocol, didFailWithError error: any Error) async {
        await delegate?.downloader(self, task: self.task, didFailWithError: error)
    }

    public var state: DownloaderState {
        get async {
            await chunkDownloader.state.toDownloaderState()
        }
    }

    public var supportProtocols: [ProtocolType] = [.http]
    private let task: any DownloadTaskProtocol
    private let chunkTask: HTTPChunkDownloadTask
    private let configure: HTTPChunkDownloadConfiguration
    private var chunkDownloader: HTTPDownloadManager!
    private var delegate: DownloaderDelegate?

    public func start() async {
        await chunkDownloader.start()
    }

    public func pause() async {
        await chunkDownloader.pause()
    }

    public func resume() async {
        await chunkDownloader.resume()
    }

    public func cancel() async {
        await chunkDownloader.cancel()
    }

    public func cleanup() async {
        await chunkDownloader.cleanup()
    }

    init(task: DownloadTaskProtocol, delegate: DownloaderDelegate) {
        self.delegate = delegate
        self.task = task
        let chunkTask = HTTPChunkDownloadTask(task: task)
        self.chunkTask = chunkTask
        let configure = HTTPChunkDownloadConfiguration(chunkSize: task.taskConfigure.chunkSize, maxConcurrentChunks: task.taskConfigure.maxConcurrentChunks, progressUpdateInterval: 0.1, bufferSize: 32 * 1024)
        self.configure = configure
        chunkDownloader = HTTPDownloadManager(downloadTask: chunkTask, configuration: configure, delegate: self)
    }
}

private class HTTPDownloaderFactory: NSObject, DownloaderFactory {
    func downloader(for: ProtocolType, task: DownloadTaskProtocol, delegate: DownloaderDelegate) async throws -> Downloader {
        DownloadManager_HTTPDownloader(task: task, delegate: delegate)
    }
}

public func registerHTTPDownloader() {
    DownloaderFactoryCenter.shared.register(factory: HTTPDownloaderFactory(), for: .http)
}
