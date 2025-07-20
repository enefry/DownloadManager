//
//  DownloadError.swift
//  DownloadManager
//
//  Created by chen on 2025/6/22.
//
import Foundation
/// 下载错误类型
public struct DownloadError: Error, CustomStringConvertible, Codable, Sendable, Hashable, Equatable {
    /// 错误码
    public let code: Int
    /// 错误描述
    public let description: String

    public init(code: Int, description: String) {
        self.code = code
        self.description = description
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        description = try container.decode(String.self, forKey: .description)
    }

    enum CodingKeys: CodingKey {
        case code
        case description
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(description, forKey: .description)
    }

    public static func from(_ error: any Error) -> DownloadError {
        if let err = error as? DownloadError {
            return err
        } else {
            let err = error as NSError
            return DownloadError(code: err.code, description: error.localizedDescription)
        }
    }

    public static let unknown = DownloadError(code: -1, description: "未知状态类型")
    public static let cancelled = DownloadError(code: -2, description: "下载被取消")
    public static let timeout = DownloadError(code: -3, description: "下载超时")
    public static let serverNotSupported = DownloadError(code: -4, description: "服务器不支持")
    public static let insufficientDiskSpace = DownloadError(code: -5, description: "磁盘空间不足")
    public static let invalidResponse = DownloadError(code: -6, description: "服务器返回无效响应")
    
    public static func networkError(_ desc: String) -> DownloadError {
        return .init(code: -7, description: desc)
    }

    public static func fileSystemError(_ desc: String) -> DownloadError {
        return .init(code: -8, description: desc)
    }

    public static func fileIOError(_ desc: String) -> DownloadError {
        return .init(code: -9, description: desc)
    }
}
