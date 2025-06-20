//
//  String+Hash.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/15.
//

import CryptoKit // 重新引入 CryptoKit，用于 sha256() 实现
import Foundation

extension String {
    public func dm_md5() -> String {
        return data(using: .utf8)?.dm_md5() ?? ""
    }

    public func dm_sha1() -> String {
        return data(using: .utf8)?.dm_sha1() ?? ""
    }

    public func dm_sha256() -> String {
        return data(using: .utf8)?.dm_sha256() ?? ""
    }

    public func dm_sha384() -> String {
        return data(using: .utf8)?.dm_sha384() ?? ""
    }

    public func dm_sha512() -> String {
        return data(using: .utf8)?.dm_sha512() ?? ""
    }

    public func dm_crc32() -> String {
        return data(using: .utf8)?.dm_crc32() ?? ""
    }
}

extension Data {
    public func dm_md5() -> String {
        let digest = Insecure.MD5.hash(data: self)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    public func dm_sha1() -> String {
        let digest = Insecure.SHA1.hash(data: self)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    public func dm_sha256() -> String {
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    public func dm_sha384() -> String {
        let digest = SHA384.hash(data: self)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    public func dm_sha512() -> String {
        let digest = SHA512.hash(data: self)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    public func dm_crc32() -> String {
        return CRC32.crc32(data: self)
    }
}
