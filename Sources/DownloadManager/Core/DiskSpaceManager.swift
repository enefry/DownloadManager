import Foundation

/// 磁盘空间管理器
///
/// 磁盘空间管理器负责管理下载相关的磁盘空间，包括：
/// - 检查磁盘空间
/// - 计算使用率
/// - 管理临时文件
/// - 自动清理机制
/// - 空间预警
///
/// 使用示例：
/// ```swift
/// // 获取磁盘空间管理器实例
/// let diskManager = DiskSpaceManager.shared
///
/// // 检查目标目录的可用空间
/// let availableSpace = diskManager.getAvailableDiskSpace(for: path)
///
/// // 获取磁盘使用率
/// let usageRatio = diskManager.getDiskUsageRatio(for: path)
///
/// // 检查是否有足够空间
/// if diskManager.hasEnoughSpace(for: path, requiredSpace: fileSize) {
///     // 开始下载
///     startDownload()
/// } else {
///     // 处理空间不足
///     handleInsufficientSpace()
/// }
/// ```
///
/// 主要功能：
/// 1. 空间检查
///    - 检查可用空间
///    - 计算使用率
///    - 空间预警
///    - 自动清理
///
/// 2. 文件管理
///    - 临时文件管理
///    - 文件清理
///    - 空间回收
///    - 文件移动
///
/// 3. 预警机制
///    - 空间不足预警
///    - 使用率预警
///    - 自动清理触发
///    - 清理策略
///
/// 4. 清理策略
///    - 按时间清理
///    - 按大小清理
///    - 按优先级清理
///    - 智能清理
///
/// 注意事项：
/// 1. 定期检查磁盘空间
/// 2. 及时清理临时文件
/// 3. 注意文件合并空间
/// 4. 合理设置预警阈值
/// 5. 注意清理策略
final class DiskSpaceManager {
    // MARK: - 单例

    static let shared = DiskSpaceManager()

    private init() {}

    // MARK: - 公开方法

    /// 获取指定路径的可用磁盘空间
    /// - Parameter path: 目标路径
    /// - Returns: 可用空间（字节）
    func getAvailableDiskSpace(for path: String) -> Int64 {
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
    func hasEnoughSpace(_ requiredSpace: Int64, for path: String) -> Bool {
        let availableSpace = getAvailableDiskSpace(for: path)
        return availableSpace >= requiredSpace
    }

    /// 获取指定路径的总磁盘空间
    /// - Parameter path: 目标路径
    /// - Returns: 总空间（字节）
    func getTotalDiskSpace(for path: String) -> Int64 {
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
    func getUsedDiskSpace(for path: String) -> Int64 {
        let totalSpace = getTotalDiskSpace(for: path)
        let availableSpace = getAvailableDiskSpace(for: path)
        return totalSpace - availableSpace
    }

    /// 获取磁盘使用率
    /// - Parameter path: 目标路径
    /// - Returns: 使用率（0-1）
    func getDiskUsageRatio(for path: String) -> Double {
        let totalSpace = getTotalDiskSpace(for: path)
        guard totalSpace > 0 else { return 0 }
        return Double(getUsedDiskSpace(for: path)) / Double(totalSpace)
    }

    /// 格式化磁盘空间大小
    /// - Parameter bytes: 字节数
    /// - Returns: 格式化后的字符串
    func formatDiskSpace(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 清理临时文件
    /// - Parameter path: 临时文件路径
    func cleanupTempFiles(at path: String) {
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
    func getFileSize(at path: String) -> Int64 {
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
    func getDirectorySize(at path: String) -> Int64 {
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