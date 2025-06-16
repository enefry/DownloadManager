import Foundation

/// 下载持久化管理器
final class DownloadPersistenceManager {
    // MARK: - 私有属性

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.downloadmanager.persistence", qos: .utility)

    private var persistenceURL: URL {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("DownloadManager")
            .appendingPathComponent("tasks.json")
    }

    // MARK: - 初始化

    init() {
        createDirectoryIfNeeded()
    }

    // MARK: - 公开方法

    func saveTasks(_ tasks: [DownloadTask]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let data = try JSONEncoder().encode(tasks)
                try data.write(to: self.persistenceURL)
            } catch {
                print("保存下载任务失败: \(error)")
            }
        }
    }

    func loadTasks() -> [DownloadTask] {
        queue.sync {
            guard let data = try? Data(contentsOf: persistenceURL),
                  let tasks = try? JSONDecoder().decode([DownloadTask].self, from: data) else {
                return []
            }
            return tasks
        }
    }

    func clearTasks() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? self.fileManager.removeItem(at: self.persistenceURL)
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
