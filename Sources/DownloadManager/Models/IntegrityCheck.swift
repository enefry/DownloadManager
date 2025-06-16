import CryptoKit
import Foundation

/// 文件完整性校验类型
public enum IntegrityCheckType: String, Codable {
    /// MD5 校验
    case md5
    /// SHA1 校验
    case sha1
    /// SHA256 校验
    case sha256
    /// CRC32 校验
    case crc32
    /// 文件大小校验
    case fileSize
    /// 从响应头获取校验信息
    case fromResponseHeaders
}

/// 文件完整性校验结果
public enum IntegrityCheckResult {
    /// 校验通过
    case success
    /// 校验失败
    case failure(Error)
}

/// 文件完整性校验错误
public enum IntegrityCheckError: LocalizedError {
    /// 校验值不匹配
    case hashMismatch(expected: String, actual: String)
    /// 文件大小不匹配
    case sizeMismatch(expected: Int64, actual: Int64)
    /// 文件不存在
    case fileNotFound
    /// 读取文件失败
    case readError(Error)
    /// 响应头中未找到校验信息
    case noChecksumInHeaders
    /// 未知错误
    case unknown(Error)

    public var errorDescription: String? {
        switch self {
        case let .hashMismatch(expected, actual):
            return "校验值不匹配: 期望 \(expected), 实际 \(actual)"
        case let .sizeMismatch(expected, actual):
            return "文件大小不匹配: 期望 \(expected), 实际 \(actual)"
        case .fileNotFound:
            return "文件不存在"
        case let .readError(error):
            return "读取文件失败: \(error.localizedDescription)"
        case .noChecksumInHeaders:
            return "响应头中未找到校验信息"
        case let .unknown(error):
            return "未知错误: \(error.localizedDescription)"
            
                
        }
    }
}

/// 文件完整性校验器
public final class IntegrityChecker {
    /// 执行文件完整性校验
    /// - Parameters:
    ///   - fileURL: 文件URL
    ///   - checkType: 校验类型
    ///   - responseHeaders: HTTP 响应头
    /// - Returns: 校验结果
    public static func check(
        fileURL: URL,
        checkType: IntegrityCheckType,
        responseHeaders: [String: String]? = nil
    ) -> IntegrityCheckResult {
        do {
            switch checkType {
            case .md5:
                let actualHash = try calculateHash(for: fileURL, type: .md5)
                return .success
            case .sha1:
                let actualHash = try calculateHash(for: fileURL, type: .sha1)
                return .success
            case .sha256:
                let actualHash = try calculateHash(for: fileURL, type: .sha256)
                return .success
            case .crc32:
                let actualHash = try calculateHash(for: fileURL, type: .crc32)
                return .success
            case .fileSize:
                let actualSize = try calculateHash(for: fileURL, type: .fileSize)
                return .success
            case .fromResponseHeaders:
                guard let headers = responseHeaders else {
                    return .failure(IntegrityCheckError.noChecksumInHeaders)
                }
                return try checkWithResponseHeaders(fileURL: fileURL, headers: headers)
            }
        } catch {
            return .failure(IntegrityCheckError.unknown(error))
        }
    }

    /// 计算文件的哈希值
    public static func calculateHash(for url: URL, type: IntegrityCheckType) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        switch type {
        case .md5, .sha1, .sha256:
            return try calculateIncrementalHash(for: fileHandle, type: type)
        case .crc32:
            return try calculateCRC32(for: fileHandle)
        case .fileSize:
            return try calculateFileSize(for: url)
        case .fromResponseHeaders:
            throw IntegrityCheckError.noChecksumInHeaders
        }
    }

    /// 计算增量哈希值（MD5、SHA1、SHA256）
    private static func calculateIncrementalHash(for fileHandle: FileHandle, type: IntegrityCheckType) throws -> String {
        let blockSize = 8192 // 8KB 块大小

        switch type {
        case .md5:
            var hasher = Insecure.MD5()
            while let data = try fileHandle.read(upToCount: blockSize) {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()

        case .sha1:
            var hasher = Insecure.SHA1()
            while let data = try fileHandle.read(upToCount: blockSize) {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()

        case .sha256:
            var hasher = SHA256()
            while let data = try fileHandle.read(upToCount: blockSize) {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()

        case .crc32, .fileSize, .fromResponseHeaders:
            throw IntegrityCheckError.unknown(NSError(domain: "Hash", code: -1, userInfo: [NSLocalizedDescriptionKey: "不支持的哈希类型"]))
        }
    }

    /// 计算 CRC32 哈希值
    private static func calculateCRC32(for fileHandle: FileHandle) throws -> String {
        let blockSize = 8192 // 8KB 块大小
        var data = Data()

        while let chunk = try fileHandle.read(upToCount: blockSize) {
            data.append(chunk)
        }

        return CRC32.crc32(data: data)
    }

    /// 计算文件大小
    private static func calculateFileSize(for url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let fileSize = attributes[.size] as? Int64 {
            return String(fileSize)
        } else {
            throw IntegrityCheckError.readError(NSError(domain: "FileSystem", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取文件大小"]))
        }
    }

    /// 从响应头中获取校验信息并验证
    private static func checkWithResponseHeaders(fileURL: URL, headers: [String: String]) throws -> IntegrityCheckResult {
        // 常见的校验头字段
        let checksumHeaders = [
            "Content-MD5": { try calculateHash(for: fileURL, type: .md5) },
            "X-Checksum-MD5": { try calculateHash(for: fileURL, type: .md5) },
            "X-Content-MD5": { try calculateHash(for: fileURL, type: .md5) },
            "ETag": { try calculateHash(for: fileURL, type: .md5) },
            "X-Checksum-SHA1": { try calculateHash(for: fileURL, type: .sha1) },
            "X-Content-SHA1": { try calculateHash(for: fileURL, type: .sha1) },
            "X-Checksum-SHA256": { try calculateHash(for: fileURL, type: .sha256) },
            "X-Content-SHA256": { try calculateHash(for: fileURL, type: .sha256) },
            "X-Checksum-CRC32": { try calculateHash(for: fileURL, type: .crc32) },
            "X-Content-CRC32": { try calculateHash(for: fileURL, type: .crc32) },
        ]

        // 遍历所有可能的校验头字段
        for (headerName, hashCalculator) in checksumHeaders {
            if let expectedHash = headers[headerName] {
                let actualHash = try hashCalculator()
                if actualHash == expectedHash {
                    return .success
                } else {
                    return .failure(IntegrityCheckError.hashMismatch(expected: expectedHash, actual: actualHash))
                }
            }
        }

        // 检查 Content-Length
        if let contentLengthStr = headers["Content-Length"],
           let expectedSize = Int64(contentLengthStr) {
            let actualSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 ?? 0
            if actualSize == expectedSize {
                return .success
            } else {
                return .failure(IntegrityCheckError.sizeMismatch(expected: expectedSize, actual: actualSize))
            }
        }

        return .failure(IntegrityCheckError.noChecksumInHeaders)
    }
}
