//
//  CRC32.swift
//  DownloadManager
//
//  Created by chen on 2025/6/15.
//

import CryptoKit // 重新引入 CryptoKit，用于 sha256() 实现
import Foundation

public struct CRC32 {
    // CRC32 查找表
    private static let crc32Table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0 ..< 256 {
            var crc: UInt32 = UInt32(i)
            for _ in 0 ..< 8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
            table[i] = crc
        }
        return table
    }()

    public static func crc32(data: Data) -> String {
        var crc32 = CRC32()
        crc32.update(data: data)
        return String(format: "%08x", crc32.finalize())
    }

    private var seed: UInt32 = 0xFFFFFFFF
    public init() {
    }

    public mutating func update(data: Data) {
        var crc: UInt32 = seed
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                crc = (crc >> 8) ^ CRC32.crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)]
            }
        }
        seed = crc
    }

    public func finalize() -> UInt32 {
        return ~seed
    }
}
