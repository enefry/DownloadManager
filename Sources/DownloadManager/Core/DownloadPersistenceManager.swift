import Foundation
import LoggerProxy

private let kLogTag = "DM.PM"

/// 下载持久化管理器
public class DownloadPersistenceManager: DownloadPersistenceManagerProtocol, @unchecked Sendable {
    var workingDirectoryName: String = "DownloadManager"
    public func setup(configure: DownloadManagerConfiguration) async {
        workingDirectoryName = configure.name.isEmpty ? "DownloadManager" : "DownloadManager-\(configure.name)"
        createDirectoryIfNeeded()
    }

    // MARK: - 私有属性

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.downloadmanager.persistence", qos: .utility)

    private var persistenceURL: URL {
        let documentsPath = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent(workingDirectoryName)
            .appendingPathComponent("tasks.json")
    }

    // MARK: - 公开方法

    public func saveTasks(_ tasks: [DownloadTask]) async throws {
        try await withCheckedThrowingContinuation { [weak self] cc in
            self?.queue.async {
                guard let self = self else { return }
                do {
                    let data = try JSONEncoder().encode(tasks)
                    try data.write(to: self.persistenceURL)
                    cc.resume(returning: ())
                } catch {
                    print("保存下载任务失败: \(error)")
                    cc.resume(throwing: error)
                }
            }
        }
    }

    public func loadTasks() async throws -> [DownloadTask] {
        try await withCheckedThrowingContinuation { [weak self] cc in
            self?.queue.sync {
                do {
                    guard let self = self else { return }
                    let data = try Data(contentsOf: self.persistenceURL)
                    let tasks = try JSONDecoder().decode([DownloadTask].self, from: data)
                    cc.resume(returning: tasks)
                } catch {
                    cc.resume(throwing: error)
                }
            }
        }
    }

    public func clearTasks() async throws {
        try await withCheckedThrowingContinuation { [weak self] cc in
            self?.queue.async {
                do {
                    guard let self = self else { return }
                    try self.fileManager.removeItem(at: self.persistenceURL)
                    cc.resume(returning: ())
                } catch {
                    cc.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 私有方法

    private func createDirectoryIfNeeded() {
        let directoryURL = persistenceURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }
}
