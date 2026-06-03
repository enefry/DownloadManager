import Foundation

public enum IntegrityHashType: Sendable, Hashable, Equatable {
    case md5
    case sha1
    case sha256
    case sha384
    case sha512
    case crc32
}

public enum IntegrityChecker {
    public static func calculateHash(for fileURL: URL, type: IntegrityHashType) throws -> String {
        let data = try Data(contentsOf: fileURL)
        switch type {
        case .md5:
            return data.dm_md5()
        case .sha1:
            return data.dm_sha1()
        case .sha256:
            return data.dm_sha256()
        case .sha384:
            return data.dm_sha384()
        case .sha512:
            return data.dm_sha512()
        case .crc32:
            return data.dm_crc32()
        }
    }
}
