//
//  ChunkDownloadTask.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/22.
//
import DownloadManagerBasic
import Foundation

public protocol HTTPChunkDownloadTaskProtocol: BasicTaskProtocol {
    var urlSessionConfigure: URLSessionConfiguration { get }
    func request(for method: String, headers: [String: String]?) async throws -> URLRequest
}

public extension HTTPChunkDownloadTaskProtocol {
    func buildRequest(method: String = "GET", headers: [String: String]? = nil) async throws -> URLRequest {
        try await request(for: method, headers: headers)
    }
}
