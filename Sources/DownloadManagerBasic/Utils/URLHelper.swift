//
//  URLHelper.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/30.
//

import Foundation

enum URLHelperError: Error {
    case invalidURL
    case bookmarkCreationFailed
    case bookmarkResolutionFailed
    case staleBookmark
    case accessDenied
    case alreadyAccessing
    case notAccessing
    case parentDirectoryNotFound
    case noWritePermission
}

/// URL 保存数据的结构体
private struct URLData: Codable {
    let urlString: String
    let isFileURL: Bool
    let bookmarkData: Data?
    let parentBookmarkData: Data?  // 父目录的 bookmark（用于不存在的文件）
    let relativePath: String?      // 相对于父目录的路径
    let creationDate: Date
    let isRemote: Bool
    
    enum CodingKeys: String, CodingKey {
        case urlString, isFileURL, bookmarkData, parentBookmarkData, relativePath, creationDate, isRemote
    }
}

public class URLHelper {
    // 使用线程安全的访问控制
    private static let queue = DispatchQueue(label: "URLHelper.queue", attributes: .concurrent)
    private static var _accessingURLs: Set<URL> = []
    
    // MARK: - Access Management
    
    /// 开始访问 security-scoped resource（仅 macOS）
    /// - Parameter url: 需要访问的文件 URL
    /// - Returns: 是否成功开始访问
    /// - Throws: URLHelperError
    /// - Note: 在 iOS 上此方法始终返回 true，因为 iOS 不需要显式的 security scope 管理
    @discardableResult
    public static func startAccess(for url: URL) throws -> Bool {
        guard url.isFileURL else {
            throw URLHelperError.invalidURL
        }
        
        return try queue.sync(flags: .barrier) {
            // 检查是否已经在访问
            if _accessingURLs.contains(url) {
                throw URLHelperError.alreadyAccessing
            }
            
#if os(macOS)
            // macOS 需要显式管理 security-scoped resource
            let success = url.startAccessingSecurityScopedResource()
            if success {
                _accessingURLs.insert(url)
                print("✅ Started accessing: \(url.lastPathComponent)")
            } else {
                print("⚠️ Failed to start accessing: \(url.lastPathComponent)")
            }
            return success
#else
            // iOS 不需要 security scope 管理，直接标记为访问中
            _accessingURLs.insert(url)
            print("✅ Started accessing: \(url.lastPathComponent)")
            return true
#endif
        }
    }
    
    /// 停止访问 security-scoped resource（仅 macOS）
    /// - Parameter url: 需要停止访问的文件 URL
    /// - Throws: URLHelperError.notAccessing 如果没有在访问该 URL
    /// - Note: 在 iOS 上此方法只会从访问列表中移除 URL
    public static func stopAccess(for url: URL) throws {
        try queue.sync(flags: .barrier) {
            guard _accessingURLs.contains(url) else {
                throw URLHelperError.notAccessing
            }
            
#if os(macOS)
            url.stopAccessingSecurityScopedResource()
#endif
            
            _accessingURLs.remove(url)
            print("🛑 Stopped accessing: \(url.lastPathComponent)")
        }
    }
    
    /// 安全地停止访问（不抛出异常）
    /// - Parameter url: 需要停止访问的文件 URL
    /// - Returns: 是否成功停止访问
    @discardableResult
    public static func stopAccessSafely(for url: URL) -> Bool {
        do {
            try stopAccess(for: url)
            return true
        } catch {
            return false
        }
    }
    
    /// 检查 URL 是否正在被访问
    /// - Parameter url: 要检查的 URL
    /// - Returns: 是否正在访问
    public static func isAccessing(url: URL) -> Bool {
        return queue.sync { _accessingURLs.contains(url) }
    }
    
    /// 获取当前正在访问的所有 URL
    /// - Returns: 正在访问的 URL 集合
    public static func getAccessingURLs() -> Set<URL> {
        return queue.sync { _accessingURLs }
    }
    
    /// 停止访问所有 URL
    /// - Returns: 成功停止访问的 URL 数量
    @discardableResult
    public static func stopAllAccess() -> Int {
        return queue.sync(flags: .barrier) {
            let count = _accessingURLs.count
            
#if os(macOS)
            for url in _accessingURLs {
                url.stopAccessingSecurityScopedResource()
                print("🛑 Stopped accessing: \(url.lastPathComponent)")
            }
#else
            for url in _accessingURLs {
                print("🛑 Stopped accessing: \(url.lastPathComponent)")
            }
#endif
            
            _accessingURLs.removeAll()
            return count
        }
    }
    
    // MARK: - Enhanced Bookmark Operations
    
    /// 为任意 URL 生成保存数据（支持不存在的文件）
    /// - Parameter url: 要保存的 URL
    /// - Returns: 序列化的 URL 数据
    /// - Throws: URLHelperError
    public static func dataFor(url: URL) throws -> Data {
        if !url.isFileURL {
            // 远程 URL 处理
            let urlData = URLData(
                urlString: url.absoluteString,
                isFileURL: false,
                bookmarkData: nil,
                parentBookmarkData: nil,
                relativePath: nil,
                creationDate: Date(),
                isRemote: true
            )
            return try JSONEncoder().encode(urlData)
        }
        
        // 文件 URL 处理
        return try createFileURLData(for: url)
    }
    
    /// 通过保存的数据恢复 URL
    /// - Parameter data: 保存的 URL 数据
    /// - Returns: 恢复的 URL
    /// - Throws: URLHelperError
    /// - Note: 对于文件 URL，需要手动调用 startAccess(for:) 来开始访问
    public static func urlFor(data: Data) throws -> URL {
        // 尝试新格式解析
        if let urlData = try? JSONDecoder().decode(URLData.self, from: data) {
            return try restoreURL(from: urlData)
        }
        
        // 兼容旧格式（纯字符串或 bookmark）
        return try legacyURLRestore(from: data)
    }
    
    /// 检查保存的 URL 数据是否仍然有效
    /// - Parameter data: 保存的 URL 数据
    /// - Returns: 是否有效
    public static func isValid(data: Data) -> Bool {
        do {
            let url = try urlFor(data: data)
            return isAccessible(url: url)
        } catch {
            return false
        }
    }
    
    /// 尝试刷新过期的 URL 数据
    /// - Parameter data: 可能过期的 URL 数据
    /// - Returns: 刷新后的 URL 数据，如果无法刷新则返回 nil
    public static func refreshData(_ data: Data) -> Data? {
        do {
            let url = try urlFor(data: data)
            if isAccessible(url: url) {
                return try dataFor(url: url)
            }
        } catch {
            // 尝试从旧数据中提取路径信息，创建新的 URL
            if let urlData = try? JSONDecoder().decode(URLData.self, from: data),
               urlData.isFileURL {
                let newURL = URL(fileURLWithPath: urlData.urlString)
                return try? dataFor(url: newURL)
            }
        }
        return nil
    }
    
    // MARK: - Private Methods
    
    private static func createFileURLData(for url: URL) throws -> Data {
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        
        if fileExists {
            // 文件存在，创建常规 bookmark
            return try createExistingFileData(for: url)
        } else {
            // 文件不存在，创建基于父目录的数据
            return try createNonExistingFileData(for: url)
        }
    }
    
    private static func createExistingFileData(for url: URL) throws -> Data {
        // 临时获取访问权限用于创建 bookmark
        let needsTemporaryAccess = !isAccessing(url: url)
        var temporaryAccess = false
        
        if needsTemporaryAccess {
#if os(macOS)
            temporaryAccess = url.startAccessingSecurityScopedResource()
#else
            temporaryAccess = true
#endif
        }
        
        defer {
#if os(macOS)
            if temporaryAccess {
                url.stopAccessingSecurityScopedResource()
            }
#endif
        }
        
        do {
            // iOS 和 macOS 使用不同的 bookmark 选项
            var options: URL.BookmarkCreationOptions = []
            
#if os(macOS)
            let hasSecurityScope = temporaryAccess || isAccessing(url: url)
            if hasSecurityScope {
                options = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
            }
#endif
            
            let bookmarkData = try url.bookmarkData(
                options: options,
                includingResourceValuesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                relativeTo: nil
            )
            
            let urlData = URLData(
                urlString: url.path,
                isFileURL: true,
                bookmarkData: bookmarkData,
                parentBookmarkData: nil,
                relativePath: nil,
                creationDate: Date(),
                isRemote: false
            )
            
            return try JSONEncoder().encode(urlData)
            
        } catch {
            print("❌ Bookmark creation failed for \(url.lastPathComponent): \(error)")
            throw URLHelperError.bookmarkCreationFailed
        }
    }
    
    private static func createNonExistingFileData(for url: URL) throws -> Data {
        let parentURL = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent
        
        // 检查父目录是否存在
        guard FileManager.default.fileExists(atPath: parentURL.path) else {
            throw URLHelperError.parentDirectoryNotFound
        }
        
        // 检查父目录是否有写权限
        guard FileManager.default.isWritableFile(atPath: parentURL.path) else {
            throw URLHelperError.noWritePermission
        }
        
        // 为父目录创建 bookmark
        let needsTemporaryAccess = !isAccessing(url: parentURL)
        var temporaryAccess = false
        
        if needsTemporaryAccess {
#if os(macOS)
            temporaryAccess = parentURL.startAccessingSecurityScopedResource()
#else
            temporaryAccess = true
#endif
        }
        
        defer {
#if os(macOS)
            if temporaryAccess {
                parentURL.stopAccessingSecurityScopedResource()
            }
#endif
        }
        
        do {
            var options: URL.BookmarkCreationOptions = []
            
#if os(macOS)
            if temporaryAccess || isAccessing(url: parentURL) {
                options = [.withSecurityScope]
            }
#endif
            
            let parentBookmarkData = try parentURL.bookmarkData(
                options: options,
                includingResourceValuesForKeys: [.isDirectoryKey],
                relativeTo: nil
            )
            
            let urlData = URLData(
                urlString: url.path,
                isFileURL: true,
                bookmarkData: nil,
                parentBookmarkData: parentBookmarkData,
                relativePath: fileName,
                creationDate: Date(),
                isRemote: false
            )
            
            return try JSONEncoder().encode(urlData)
            
        } catch {
            print("❌ Parent bookmark creation failed for \(parentURL.lastPathComponent): \(error)")
            throw URLHelperError.bookmarkCreationFailed
        }
    }
    
    private static func restoreURL(from urlData: URLData) throws -> URL {
        if urlData.isRemote {
            // 远程 URL
            guard let url = URL(string: urlData.urlString) else {
                throw URLHelperError.invalidURL
            }
            return url
        }
        
        // 文件 URL
        if let bookmarkData = urlData.bookmarkData {
            // 存在文件的 bookmark
            return try resolveFileBookmark(data: bookmarkData)
        } else if let parentBookmarkData = urlData.parentBookmarkData,
                  let relativePath = urlData.relativePath {
            // 不存在文件的父目录 bookmark
            return try resolveNonExistingFileURL(
                parentBookmarkData: parentBookmarkData,
                relativePath: relativePath
            )
        } else {
            // 降级到路径恢复
            return URL(fileURLWithPath: urlData.urlString)
        }
    }
    
    private static func resolveFileBookmark(data: Data) throws -> URL {
        var isStale = false
        
        do {
#if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withoutUI, .withSecurityScope]
#else
            let options: URL.BookmarkResolutionOptions = [.withoutUI]
#endif
            
            let url = try URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if isStale {
                print("⚠️ Bookmark is stale for URL: \(url.lastPathComponent)")
                throw URLHelperError.staleBookmark
            }
            
            print("✅ Resolved bookmark for: \(url.lastPathComponent)")
            return url
            
        } catch {
            print("❌ Bookmark resolution failed: \(error)")
            throw URLHelperError.bookmarkResolutionFailed
        }
    }
    
    private static func resolveNonExistingFileURL(parentBookmarkData: Data, relativePath: String) throws -> URL {
        // 首先恢复父目录
        let parentURL = try resolveFileBookmark(data: parentBookmarkData)
        
        // 组合完整路径
        let fileURL = parentURL.appendingPathComponent(relativePath)
        
        print("✅ Resolved non-existing file URL: \(fileURL.lastPathComponent)")
        return fileURL
    }
    
    private static func legacyURLRestore(from data: Data) throws -> URL {
        // 尝试当作 bookmark 解析
        if let url = try? resolveFileBookmark(data: data) {
            return url
        }
        
        // 尝试当作字符串解析
        guard let urlString = String(data: data, encoding: .utf8),
              let url = URL(string: urlString) else {
            throw URLHelperError.bookmarkResolutionFailed
        }
        
        return url
    }
}

// MARK: - URLHelper + Convenience

extension URLHelper {
    /// 便捷方法：检查 URL 是否可访问
    /// - Parameter url: 要检查的 URL
    /// - Returns: 是否可访问
    public static func isAccessible(url: URL) -> Bool {
        if url.isFileURL {
            let fileExists = FileManager.default.fileExists(atPath: url.path)
            if fileExists {
                return true
            } else {
                // 检查父目录是否存在且可写
                let parentURL = url.deletingLastPathComponent()
                return FileManager.default.fileExists(atPath: parentURL.path) &&
                FileManager.default.isWritableFile(atPath: parentURL.path)
            }
        } else {
            return url.scheme != nil && url.host != nil
        }
    }
    
    /// 便捷方法：安全地获取文件 URL 的资源值
    /// - Parameters:
    ///   - url: 文件 URL
    ///   - keys: 要获取的资源键
    /// - Returns: URL 资源值
    /// - Throws: URLHelperError
    /// - Note: 如果 URL 没有被访问，会临时获取访问权限
    public static func resourceValues(for url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
        guard url.isFileURL else {
            throw URLHelperError.invalidURL
        }
        
        // 只有文件存在时才能获取资源值
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw URLHelperError.invalidURL
        }
        
        let needsTemporaryAccess = !isAccessing(url: url)
        var temporaryAccess = false
        
        if needsTemporaryAccess {
#if os(macOS)
            temporaryAccess = url.startAccessingSecurityScopedResource()
#else
            temporaryAccess = true
#endif
        }
        
        defer {
#if os(macOS)
            if temporaryAccess {
                url.stopAccessingSecurityScopedResource()
            }
#endif
        }
        
        return try url.resourceValues(forKeys: keys)
    }
    
    /// 便捷方法：在闭包中安全地访问文件 URL
    /// - Parameters:
    ///   - url: 文件 URL
    ///   - block: 访问闭包
    /// - Returns: 闭包的返回值
    /// - Throws: URLHelperError 或闭包抛出的错误
    public static func withAccess<T>(to url: URL, _ block: (URL) throws -> T) throws -> T {
        let wasAccessing = isAccessing(url: url)
        
        if !wasAccessing {
            try startAccess(for: url)
        }
        
        defer {
            if !wasAccessing {
                stopAccessSafely(for: url)
            }
        }
        
        return try block(url)
    }
    
    /// 便捷方法：创建文件并返回可访问的 URL
    /// - Parameters:
    ///   - url: 目标文件 URL
    ///   - data: 要写入的数据
    /// - Returns: 创建的文件 URL
    /// - Throws: URLHelperError
    public static func createFile(at url: URL, with data: Data) throws -> URL {
        guard url.isFileURL else {
            throw URLHelperError.invalidURL
        }
        
        // 确保父目录存在
        let parentURL = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentURL.path) {
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        }
        
        // 写入文件
        try data.write(to: url)
        
        print("✅ Created file: \(url.lastPathComponent)")
        return url
    }
    
    /// 便捷方法：安全地创建或写入文件
    /// - Parameters:
    ///   - url: 目标文件 URL
    ///   - data: 要写入的数据
    ///   - block: 写入成功后的处理闭包
    /// - Returns: 闭包的返回值
    /// - Throws: URLHelperError 或闭包抛出的错误
    public static func createFileWithAccess<T>(at url: URL, with data: Data, _ block: (URL) throws -> T) throws -> T {
        let createdURL = try createFile(at: url, with: data)
        return try withAccess(to: createdURL, block)
    }
    
    /// 便捷方法：批量保存 URL 数据
    /// - Parameter urls: URL 数组
    /// - Returns: 成功保存的数据字典 [URL: Data]
    public static func batchSaveURLs(_ urls: [URL]) -> [URL: Data] {
        var results: [URL: Data] = [:]
        
        for url in urls {
            do {
                let data = try dataFor(url: url)
                results[url] = data
            } catch {
                print("❌ Failed to save URL \(url.lastPathComponent): \(error)")
            }
        }
        
        return results
    }
}

// MARK: - URLHelper + Debug

#if DEBUG
extension URLHelper {
    /// 调试：打印当前访问状态
    public static func debugPrintAccessStatus() {
        let accessing = getAccessingURLs()
        print("🔍 URLHelper Debug Status:")
        print("📊 Currently accessing \(accessing.count) URLs:")
        
        for url in accessing {
            print("  📁 \(url.lastPathComponent) - \(url.path)")
        }
        
        if accessing.isEmpty {
            print("  (No URLs currently being accessed)")
        }
    }
    
    /// 调试：打印指定 URL 的状态
    /// - Parameter url: 要检查的 URL
    public static func debugPrintStatus(for url: URL) {
        print("🔍 URL Status: \(url.lastPathComponent)")
        print("  📂 Path: \(url.path)")
        print("  🔓 Is accessing: \(isAccessing(url: url))")
        print("  📋 File exists: \(FileManager.default.fileExists(atPath: url.path))")
        print("  🌐 Is file URL: \(url.isFileURL)")
        print("  ✅ Is accessible: \(isAccessible(url: url))")
    }
    
    /// 调试：分析保存的 URL 数据
    /// - Parameter data: 保存的数据
    public static func debugAnalyzeData(_ data: Data) {
        print("🔍 URL Data Analysis:")
        
        if let urlData = try? JSONDecoder().decode(URLData.self, from: data) {
            print("  📋 Format: New JSON format")
            print("  🌐 Is remote: \(urlData.isRemote)")
            print("  📁 Is file URL: \(urlData.isFileURL)")
            print("  📅 Creation date: \(urlData.creationDate)")
            print("  🔖 Has bookmark: \(urlData.bookmarkData != nil)")
            print("  📂 Has parent bookmark: \(urlData.parentBookmarkData != nil)")
            print("  📝 Relative path: \(urlData.relativePath ?? "nil")")
            print("  🛤️ Path: \(urlData.urlString)")
        } else {
            print("  📋 Format: Legacy format")
            if let string = String(data: data, encoding: .utf8) {
                print("  📝 Content: \(string)")
            } else {
                print("  📝 Content: Binary data (\(data.count) bytes)")
            }
        }
    }
}
#endif
