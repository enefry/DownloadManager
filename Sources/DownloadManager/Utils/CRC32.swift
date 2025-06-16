//
//  CRC32.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/15.
//

import CryptoKit // 重新引入 CryptoKit，用于 sha256() 实现
import Foundation

struct CRC32 {
    // CRC32 查找表
    private static var crc32Table: [UInt32] = {
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

    internal static func crc32(data: Data) -> String {
        let checksum = data.withUnsafeBytes { buffer -> UInt32 in
            var crc: UInt32 = 0xFFFFFFFF
            for byte in buffer {
                crc = (crc >> 8) ^ crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)]
            }
            return ~crc
        }
        return String(format: "%08x", checksum)
    }
}
