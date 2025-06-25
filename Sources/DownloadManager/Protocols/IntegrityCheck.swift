
///// 文件完整性校验类型
public enum IntegrityCheckType: Codable, Sendable, Hashable, Equatable {
    /// MD5 校验
    case md5(String)
    /// SHA1 校验
    case sha1(String)
    /// SHA256 校验
    case sha256(String)
    /// CRC384 校验
    case sha384(String)
    /// CRC512 校验
    case sha512(String)
    /// CRC32 校验
    case crc32(String)
    /// 文件大小校验
    case fileSize(Int64)
}
