//
//  String+Helper.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/22.
//
import Foundation

public extension FixedWidthInteger {
    func dm_formatBytes() -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file // 最适合文件大小的样式 (e.g., 1.2 MB, 500 KB)
        formatter.allowedUnits = .useAll // 允许使用所有单位 (字节、KB、MB等)
        // formatter.includesUnit = true // 总是包含单位 (默认行为)
        formatter.isAdaptive = true // 自动选择最合适的单位 (默认行为)
//         formatter.includesActualByteCount = true // 包含实际字节数 (e.g., 1.2 MB (1,234,567 bytes))
        return formatter.string(fromByteCount: Int64(truncatingIfNeeded: self))
    }
}
