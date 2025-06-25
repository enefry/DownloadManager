import Foundation

public final class DiskSpaceManager: @unchecked Sendable {
    // MARK: - 单例

    public static let shared = DiskSpaceManager()

    private init() {}

    // MARK: - 公开方法

    /// 获取指定路径的可用磁盘空间
    /// - Parameter path: 目标路径
    /// - Returns: 可用空间（字节）
    public func getAvailableDiskSpace(for path: String) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
            if let freeSpace = attributes[.systemFreeSize] as? Int64 {
                return freeSpace
            }
        } catch {
            print("获取磁盘空间失败: \(error)")
        }
        return 0
    }

    /// 检查是否有足够的磁盘空间
    /// - Parameters:
    ///   - requiredSpace: 所需空间（字节）
    ///   - path: 目标路径
    /// - Returns: 是否有足够空间
    public func hasEnoughSpace(_ requiredSpace: Int64, for path: String) -> Bool {
        let availableSpace = getAvailableDiskSpace(for: path)
        return availableSpace >= requiredSpace
    }

    /// 获取指定路径的总磁盘空间
    /// - Parameter path: 目标路径
    /// - Returns: 总空间（字节）
    public func getTotalDiskSpace(for path: String) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
            if let totalSpace = attributes[.systemSize] as? Int64 {
                return totalSpace
            }
        } catch {
            print("获取磁盘空间失败: \(error)")
        }
        return 0
    }

    /// 获取指定路径的已用磁盘空间
    /// - Parameter path: 目标路径
    /// - Returns: 已用空间（字节）
    public func getUsedDiskSpace(for path: String) -> Int64 {
        let totalSpace = getTotalDiskSpace(for: path)
        let availableSpace = getAvailableDiskSpace(for: path)
        return totalSpace - availableSpace
    }

    /// 获取磁盘使用率
    /// - Parameter path: 目标路径
    /// - Returns: 使用率（0-1）
    public func getDiskUsageRatio(for path: String) -> Double {
        let totalSpace = getTotalDiskSpace(for: path)
        guard totalSpace > 0 else { return 0 }
        return Double(getUsedDiskSpace(for: path)) / Double(totalSpace)
    }

    /// 格式化磁盘空间大小
    /// - Parameter bytes: 字节数
    /// - Returns: 格式化后的字符串
    public func formatDiskSpace(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 清理临时文件
    /// - Parameter path: 临时文件路径
    public func cleanupTempFiles(at path: String) {
        do {
            let fileManager = FileManager.default
            let tempFiles = try fileManager.contentsOfDirectory(atPath: path)

            for file in tempFiles {
                let filePath = (path as NSString).appendingPathComponent(file)
                try? fileManager.removeItem(atPath: filePath)
            }
        } catch {
            print("清理临时文件失败: \(error)")
        }
    }

    /// 获取文件大小
    /// - Parameter path: 文件路径
    /// - Returns: 文件大小（字节）
    public func getFileSize(at path: String) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let fileSize = attributes[.size] as? Int64 {
                return fileSize
            }
        } catch {
            print("获取文件大小失败: \(error)")
        }
        return 0
    }

    /// 获取目录大小
    /// - Parameter path: 目录路径
    /// - Returns: 目录大小（字节）
    public func getDirectorySize(at path: String) -> Int64 {
        var size: Int64 = 0
        let fileManager = FileManager.default

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: path)

            for file in contents {
                let filePath = (path as NSString).appendingPathComponent(file)
                let attributes = try fileManager.attributesOfItem(atPath: filePath)

                if let fileSize = attributes[.size] as? Int64 {
                    size += fileSize
                }
            }
        } catch {
            print("获取目录大小失败: \(error)")
        }

        return size
    }
}
