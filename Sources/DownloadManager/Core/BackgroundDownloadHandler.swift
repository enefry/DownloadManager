import Foundation

/// 后台下载处理器，仅负责事件分发，不做任何 UI 相关操作
public final class BackgroundDownloadHandler {
    public static let shared = BackgroundDownloadHandler()
    private var completionHandler: (() -> Void)?

    private init() {}

    /// 注册后台下载完成回调
    public func setDownloadCompletionHandler(_ handler: @escaping () -> Void) {
        completionHandler = handler
    }

    /// 触发后台下载完成事件
    public func notifyDownloadCompleted() {
        completionHandler?()
    }
}
