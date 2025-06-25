//
//  TaskState.swift
//  FileManagerDemo
//
//  Created by 陈任伟 on 2025/6/22.
//

import Combine
import DownloadManagerBasic
import Foundation

/// 下载状态，这个是给下载管理那边使用的
public enum TaskState: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    case pending
    case downloading
    case paused
    case stop
    case completed
    case failed(DownloadError)

    public var isFinished: Bool {
        switch self {
        case .pending, .downloading, .paused:
            return false
        case .stop, .completed, .failed:
            return true
        }
    }

    public var isFailed: Bool {
        switch self {
        case .pending, .downloading, .paused, .stop, .completed:
            return false
        case .failed:
            return true
        }
    }

    public var description: String {
        switch self {
        case .pending: return "pending"
        case .downloading: return "downloading"
        case .paused: return "paused"
        case .stop: return "stop"
        case .completed: return "completed"
        case let .failed(downloadError): return "Error:\(downloadError)"
        }
    }

    enum CodingKeys: CodingKey {
        case type
        case code
        case desc
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        if case let .failed(err) = self {
            try container.encode(err.code, forKey: .code)
            try container.encode(err.description, forKey: .desc)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "pending": self = .pending
        case "downloading": self = .downloading
        case "paused": self = .paused
        case "stop": self = .stop
        case "completed": self = .completed
        case "error":
            let code = try container.decode(Int.self, forKey: .code)
            let desc = try container.decode(String.self, forKey: .desc)
            self = .failed(DownloadError(code: code, description: desc))
        default:
            throw DownloadError.unknown
        }
    }

    private var type: String {
        return switch self {
        case .pending: "pending"
        case .downloading: "downloading"
        case .paused: "paused"
        case .stop: "stop"
        case .completed: "completed"
        case .failed: "error"
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending), (.downloading, .downloading), (.paused, .paused), (.stop, .stop), (.completed, .completed):
            return true
        case let (.failed(e1), .failed(e2)):
            return e1.code == e2.code && e1.description == e2.description
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        if case let .failed(err) = self {
            hasher.combine(err.code)
            hasher.combine(err.description)
        }
    }
}
