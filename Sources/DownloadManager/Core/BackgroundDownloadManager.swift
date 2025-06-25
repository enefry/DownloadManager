//import Foundation
//#if canImport(UIKit)
//    import UIKit
//#endif
//import Combine
//
///// 后台下载管理器
/////
///// 后台下载管理器负责管理应用在后台时的下载任务，包括：
///// - 配置后台下载会话
///// - 处理后台下载事件
///// - 管理后台任务标识符
///// - 处理应用状态转换
///// - 提供下载进度通知
/////
///// 使用示例：
///// ```swift
///// // 获取后台下载管理器实例
///// let backgroundManager = BackgroundDownloadManager.shared
/////
///// // 配置后台下载
///// backgroundManager.configureBackgroundDownload()
/////
///// // 创建后台下载任务
///// let task = backgroundManager.createBackgroundDownloadTask(
/////     url: url,
/////     destinationURL: destinationURL
///// )
/////
///// // 监听下载进度
///// backgroundManager.progressPublisher
/////     .sink { progress in
/////         print("后台下载进度: \(progress)")
/////     }
/////     .store(in: &cancellables)
///// ```
/////
///// 主要功能：
///// 1. 后台会话
/////    - 配置后台会话
/////    - 管理会话标识符
/////    - 处理会话事件
/////    - 恢复下载任务
/////
///// 2. 任务管理
/////    - 创建后台任务
/////    - 暂停后台任务
/////    - 恢复后台任务
/////    - 取消后台任务
/////
///// 3. 状态处理
/////    - 应用进入后台
/////    - 应用进入前台
/////    - 应用终止
/////    - 任务完成
/////
///// 4. 通知管理
/////    - 下载进度通知
/////    - 下载完成通知
/////    - 下载失败通知
/////    - 本地通知
/////
///// 注意事项：
///// 1. 配置后台模式
///// 2. 处理会话事件
///// 3. 管理任务标识符
///// 4. 注意内存管理
///// 5. 处理应用状态
//public final class BackgroundDownloadManager: NSObject {
//    // MARK: - 公开属性
//
////    public private(set) var backgroundSession: URLSession!
//    public private(set) var backgroundTasks: [String: URLSessionDownloadTask] = [:]
//    public private(set) var taskProgress: [String: Double] = [:]
//    public private(set) var taskCompletionHandlers: [String: (Result<URL, Error>) -> Void] = [:]
//
//    // MARK: - 私有属性
//
//    private let progressSubject = PassthroughSubject<(String, Double), Never>()
//    private let completionSubject = PassthroughSubject<(String, Result<URL, Error>), Never>()
//    private let queue = DispatchQueue(label: "com.downloadmanager.background", qos: .utility)
//    private let downloadHandler = BackgroundDownloadHandler.shared
//
//    // MARK: - 单例
//
//    public static let shared = BackgroundDownloadManager()
//
//    // MARK: - 初始化
//
//    override private init() {
//        super.init()
//        setupBackgroundSession()
//    }
//
//    // MARK: - 公开方法
//
//    /// 配置后台下载
//    public func configureBackgroundDownload() {
//        #if canImport(UIKit)
//            // 注册后台任务，仅 iOS 有效
//            UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
//        #else
//            // 非 iOS 平台无操作
//        #endif
//    }
//
//    /// 创建后台下载任务
//    /// - Parameters:
//    ///   - url: 下载URL
//    ///   - destinationURL: 目标URL
//    ///   - completionHandler: 完成回调
//    /// - Returns: 任务标识符
//    @discardableResult
//    public func createBackgroundDownloadTask(
//        url: URL,
//        destinationURL: URL,
//        completionHandler: @escaping (Result<URL, Error>) -> Void
//    ) -> String {
//        let taskId = UUID().uuidString
//        let request = URLRequest(url: url)
//        let task = backgroundSession.downloadTask(with: request)
//
//        queue.async { [weak self] in
//            guard let self = self else { return }
//            self.backgroundTasks[taskId] = task
//            self.taskProgress[taskId] = 0
//            self.taskCompletionHandlers[taskId] = completionHandler
//        }
//
//        task.resume()
//        return taskId
//    }
//
//    /// 暂停后台下载任务
//    /// - Parameter taskId: 任务标识符
//    public func pauseBackgroundDownload(taskId: String) {
//        queue.async { [weak self] in
//            guard let self = self,
//                  let task = self.backgroundTasks[taskId] else { return }
//            task.suspend()
//        }
//    }
//
//    /// 恢复后台下载任务
//    /// - Parameter taskId: 任务标识符
//    public func resumeBackgroundDownload(taskId: String) {
//        queue.async { [weak self] in
//            guard let self = self,
//                  let task = self.backgroundTasks[taskId] else { return }
//            task.resume()
//        }
//    }
//
//    /// 取消后台下载任务
//    /// - Parameter taskId: 任务标识符
//    public func cancelBackgroundDownload(taskId: String) {
//        queue.async { [weak self] in
//            guard let self = self,
//                  let task = self.backgroundTasks[taskId] else { return }
//            task.cancel()
//            self.cleanupTask(taskId)
//        }
//    }
//
//    /// 获取下载进度发布者
//    public var progressPublisher: AnyPublisher<(String, Double), Never> {
//        progressSubject.eraseToAnyPublisher()
//    }
//
//    /// 获取下载完成发布者
//    public var completionPublisher: AnyPublisher<(String, Result<URL, Error>), Never> {
//        completionSubject.eraseToAnyPublisher()
//    }
//
//    // MARK: - 私有方法
//
//    private func setupBackgroundSession() {
//        let configuration = URLSessionConfiguration.background(withIdentifier: "com.downloadmanager.background")
//        configuration.isDiscretionary = true
//        #if os(iOS) || os(macOS)
//            if #available(iOS 13.0, macOS 11.0, *) {
//                configuration.sessionSendsLaunchEvents = true
//            }
//        #endif
//        backgroundSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
//    }
//
//    private func cleanupTask(_ taskId: String) {
//        queue.async { [weak self] in
//            guard let self = self else { return }
//            self.backgroundTasks.removeValue(forKey: taskId)
//            self.taskProgress.removeValue(forKey: taskId)
//            self.taskCompletionHandlers.removeValue(forKey: taskId)
//        }
//    }
//
//    private func handleDownloadCompletion(taskId: String, result: Result<URL, Error>) {
//        queue.async { [weak self] in
//            guard let self = self else { return }
//            if let completionHandler = self.taskCompletionHandlers[taskId] {
//                completionHandler(result)
//            }
//            self.completionSubject.send((taskId, result))
//            self.cleanupTask(taskId)
//        }
//    }
//}
//
//// MARK: - URLSessionDownloadDelegate
//
//extension BackgroundDownloadManager: URLSessionDownloadDelegate {
//    public func urlSession(
//        _ session: URLSession,
//        downloadTask: URLSessionDownloadTask,
//        didFinishDownloadingTo location: URL
//    ) {
//        guard let taskId = downloadTask.taskDescription else { return }
//
//        do {
//            // 创建目标目录
//            let destinationURL = try FileManager.default.url(
//                for: .documentDirectory,
//                in: .userDomainMask,
//                appropriateFor: nil,
//                create: true
//            ).appendingPathComponent("Downloads/\(taskId)")
//
//            try FileManager.default.createDirectory(
//                at: destinationURL.deletingLastPathComponent(),
//                withIntermediateDirectories: true
//            )
//
//            // 如果目标文件已存在，先删除
//            if FileManager.default.fileExists(atPath: destinationURL.path) {
//                try FileManager.default.removeItem(at: destinationURL)
//            }
//
//            // 移动文件到目标位置
//            try FileManager.default.moveItem(at: location, to: destinationURL)
//            handleDownloadCompletion(taskId: taskId, result: .success(destinationURL))
//        } catch {
//            handleDownloadCompletion(taskId: taskId, result: .failure(error))
//        }
//    }
//
//    public func urlSession(
//        _ session: URLSession,
//        downloadTask: URLSessionDownloadTask,
//        didWriteData bytesWritten: Int64,
//        totalBytesWritten: Int64,
//        totalBytesExpectedToWrite: Int64
//    ) {
//        guard let taskId = downloadTask.taskDescription else { return }
//
//        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
//        queue.async { [weak self] in
//            guard let self = self else { return }
//            self.taskProgress[taskId] = progress
//            self.progressSubject.send((taskId, progress))
//        }
//    }
//
//    public func urlSession(
//        _ session: URLSession,
//        task: URLSessionTask,
//        didCompleteWithError error: Error?
//    ) {
//        guard let taskId = task.taskDescription else { return }
//
//        if let error = error {
//            handleDownloadCompletion(taskId: taskId, result: .failure(error))
//        }
//    }
//}
//
//// MARK: - URLSessionDelegate
//
//extension BackgroundDownloadManager: URLSessionDelegate {
//    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
//        DispatchQueue.main.async {
//            self.downloadHandler.notifyDownloadCompleted()
//        }
//    }
//}
