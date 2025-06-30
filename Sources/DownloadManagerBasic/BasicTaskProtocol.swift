//
//  BasicTaskProtocol.swift
//  DownloadManager
//
//  Created by chen on 2025/6/22.
//
import Foundation

public protocol BasicTaskProtocol: Sendable {
    /// 下载任务的唯一标识符
    var identifier: String { get }
    /// 源地址的URL
    var url: URL { get }
    /// 目标保存路径
    var destinationURL: URL { get }
    /// 已下载字节数
    var downloadedBytes: Int64 { get }
    /// 总字节数
    var totalBytes: Int64 { get }
}

public extension BasicTaskProtocol {
    static func buildIdentifier(url: URL, destinationURL: URL) -> String {
        return "\(url.absoluteString)\n\(destinationURL.absoluteString)".dm_sha256()
    }
}
