//
//  String+Hash.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/15.
//


import CryptoKit // 重新引入 CryptoKit，用于 sha256() 实现
import Foundation

extension String {
    func md5() -> String {
        let data = self.data(using: .utf8)!
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    func sha1() -> String {
        let data = self.data(using: .utf8)!
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    func sha256() -> String {
        let data = self.data(using: .utf8)!
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    func sha384() -> String {
        let data = self.data(using: .utf8)!
        let digest = SHA384.hash(data: data)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    func sha512() -> String {
        let data = self.data(using: .utf8)!
        let digest = SHA512.hash(data: data)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    func crc32() -> String {
        let data = self.data(using: .utf8)!
        return CRC32.crc32(data: data)
    }
}