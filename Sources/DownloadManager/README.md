# DownloadManager

一个现代化的 Swift 下载管理器，支持 Combine 和 async/await，专为 SwiftUI 应用设计。

我现在想要设计iOS一个下载管理器（最好也能给其他apple平台使用）

帮忙补充一下 DownloadManager的实现，主使用流程是：
1. DownloadManager 的 func download(url: URL, destination: URL, configuration: DownloadTaskConfiguration?) -> DownloadTaskProtocol 返回实际对象是 DownloadTask
2. DownloadTask 主要作用是记录下载信息，通知下载状态更新和进度更新
3. DownloadManager 创建 DownloadTask后会保存到队列，并通过DownloadPersistenceManager进行持久化保存。
4. DownloadManager 包含一个下载队列调度器，调度会根据 DownloadManagerConfiguration 中的并发控制，调度开始下载任务
5. DownloadManager 通过 ChunkDownloadManager 下载 DownloadTask 并监听回调，更新 DownloadTask 状态和进度
6. DownloadManager 会在 ChunkDownloadManager 报告错误后，通过RetryStrategy决策是否再次重试，并重新调度任务
7. 注意线程安全