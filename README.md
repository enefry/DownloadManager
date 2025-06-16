# PanPlayer 下载管理器

PanPlayer 下载管理器是一个功能强大的文件下载管理组件，支持单文件下载、批量下载、断点续传、分片下载等功能。

## 主要特性

### 1. 核心下载功能
- 单文件下载
- 批量下载
- 断点续传
- 分片下载
- 下载进度监控
- 下载速度限制
- 下载优先级管理

### 2. 网络管理
- 网络状态监控
- 网络类型判断（WiFi/蜂窝网络）
- 网络策略控制
- 自动重试机制

### 3. 存储管理
- 磁盘空间检查
- 临时文件管理
- 文件合并
- 自动清理机制

### 4. 错误处理
- 错误类型定义
- 重试机制
- 错误恢复建议

### 5. 统计和历史
- 下载统计
- 历史记录
- 性能指标

## 使用指南

### 1. 基本下载

```swift
// 创建下载任务
let task = try downloadManager.createDownloadTask(
    url: url,
    destinationURL: destinationURL,
    configuration: configuration
)

// 开始下载
task.resume()

// 暂停下载
task.pause()

// 取消下载
task.cancel()

// 等待下载完成
let result = try await task.waitForCompletion()
```

### 2. 批量下载

```swift
// 创建批量下载任务
let batchTask = try downloadManager.createBatchDownload(
    urls: urls,
    destinationDirectory: destinationDirectory,
    configuration: configuration
)

// 开始批量下载
downloadManager.startBatchDownload(batchId: batchTask.batchId)

// 暂停批量下载
downloadManager.pauseBatchDownload(batchId: batchTask.batchId)

// 取消批量下载
downloadManager.cancelBatchDownload(batchId: batchTask.batchId)

// 获取批量下载任务
let task = downloadManager.getBatchTask(batchId: batchId)

// 获取所有批量下载任务
let allTasks = downloadManager.getAllBatchTasks()
```

### 3. 下载配置

```swift
// 创建下载配置
let configuration = DefaultDownloadTaskConfiguration(
    timeoutInterval: 30,
    headers: ["Authorization": "Bearer token"],
    chunkSize: 1024 * 1024, // 1MB
    maxConcurrentChunks: 3,
    speedLimit: 1024 * 1024, // 1MB/s
    priority: 50,
    allowsBackgroundDownload: true,
    allowsCellularAccess: true,
    allowsConstrainedNetworkAccess: true,
    allowsExpensiveNetworkAccess: true
)

// 更新任务配置
task.updateConfiguration(newConfiguration)
```

### 4. 下载监控

```swift
// 监听下载进度
task.progressPublisher
    .sink { progress in
        print("下载进度: \(progress)")
    }
    .store(in: &cancellables)

// 监听下载状态
task.statePublisher
    .sink { state in
        print("下载状态: \(state)")
    }
    .store(in: &cancellables)

// 监听下载速度
task.speedPublisher
    .sink { speed in
        print("下载速度: \(speed) bytes/s")
    }
    .store(in: &cancellables)
```

### 5. 磁盘空间管理

```swift
// 获取下载目录的磁盘使用情况
let usage = downloadManager.getDownloadDirectoryDiskUsage()
print("总空间: \(usage.total)")
print("已用空间: \(usage.used)")
print("可用空间: \(usage.free)")

// 格式化显示磁盘使用情况
let formattedUsage = downloadManager.formatDiskUsage()
print(formattedUsage)
```

### 6. 任务优先级管理

```swift
// 设置任务优先级
downloadManager.setTaskPriority(100, forTaskWithIdentifier: taskId)

// 批量设置任务优先级
downloadManager.setTasksPriority(50, forTaskIdentifiers: [taskId1, taskId2])

// 获取任务优先级
let priority = downloadManager.getTaskPriority(forTaskWithIdentifier: taskId)

// 获取所有任务的优先级
let priorities = downloadManager.getAllTasksPriority()
```

## 高级功能

### 1. 分片下载

分片下载功能会自动将大文件分成多个小块进行下载，支持：
- 自动分片
- 并发下载
- 断点续传
- 文件合并

### 2. 批量下载

批量下载功能支持：
- 批量任务创建
- 整体进度监控
- 任务状态管理
- 持久化存储
- 自动恢复

### 3. 网络管理

网络管理功能包括：
- 网络状态监控
- 网络类型判断
- 网络策略控制
- 自动重试机制

### 4. 存储管理

存储管理功能包括：
- 磁盘空间检查
- 临时文件管理
- 文件合并
- 自动清理机制

### 5. 文件完整性校验

文件完整性校验功能支持多种校验方式，确保下载文件的完整性和正确性：

#### 支持的校验方式
- MD5 校验
- SHA1 校验
- SHA256 校验
- CRC32 校验
- 文件大小校验

#### 使用示例

```swift
// 创建带校验的下载配置
let configuration = DefaultDownloadTaskConfiguration(
    timeoutInterval: 30,
    headers: ["Authorization": "Bearer token"],
    chunkSize: 1024 * 1024, // 1MB
    maxConcurrentChunks: 3,
    speedLimit: 1024 * 1024, // 1MB/s
    priority: 50,
    allowsBackgroundDownload: true,
    allowsCellularAccess: true,
    allowsConstrainedNetworkAccess: true,
    allowsExpensiveNetworkAccess: true,
    integrityCheck: .md5("expected_md5_hash")
)

// 创建下载任务
let task = try downloadManager.createDownloadTask(
    url: url,
    destinationURL: destinationURL,
    configuration: configuration
)

// 监听校验结果
task.integrityCheckPublisher
    .sink { result in
        switch result {
        case .success:
            print("文件完整性校验通过")
        case .failure(let error):
            print("文件完整性校验失败: \(error)")
        }
    }
    .store(in: &cancellables)
```

#### 批量下载校验

```swift
// 创建批量下载任务时指定校验方式
let batchTask = try downloadManager.createBatchDownload(
    urls: urls,
    destinationDirectory: destinationDirectory,
    configuration: configuration,
    integrityChecks: [
        url1: .md5("hash1"),
        url2: .sha1("hash2"),
        url3: .fileSize(1024)
    ]
)

// 监听批量下载的校验结果
batchTask.integrityCheckPublisher
    .sink { (url, result) in
        switch result {
        case .success:
            print("文件 \(url) 完整性校验通过")
        case .failure(let error):
            print("文件 \(url) 完整性校验失败: \(error)")
        }
    }
    .store(in: &cancellables)
```

#### 校验失败处理

当文件完整性校验失败时，系统会：

1. 自动重试下载
2. 记录错误日志
3. 通知用户
4. 提供手动重试选项

#### 注意事项

1. 性能考虑
   - 大文件校验可能耗时较长
   - 建议在后台线程进行校验
   - 可以根据文件大小选择合适的校验方式

2. 存储管理
   - 校验失败的文件会被标记
   - 可以配置自动清理策略
   - 支持手动清理失败文件

3. 网络优化
   - 支持断点续传时保持校验
   - 分片下载时支持分片校验
   - 支持校验失败时自动重试

4. 安全考虑
   - 校验值应该通过安全渠道获取
   - 支持加密传输校验值
   - 防止校验值被篡改

## 错误处理

### 1. 错误类型

```swift
public enum DownloadError: Error {
    case invalidURL
    case networkError(Error)
    case timeout
    case serverError(Int)
    case fileSystemError(Error)
    case insufficientDiskSpace
    case cancelled
    case unknown(Error)
}
```

### 2. 重试机制

- 网络错误自动重试
- 服务器错误自动重试
- 超时自动重试
- 可配置重试次数和间隔

## 性能优化

### 1. 内存管理
- 分片下载减少内存占用
- 临时文件管理
- 自动清理机制

### 2. 并发控制
- 最大并发数限制
- 任务优先级管理
- 网络类型适配

### 3. 磁盘管理
- 磁盘空间检查
- 自动清理机制
- 文件合并优化

## 注意事项

1. 权限要求
   - 网络访问权限
   - 文件系统访问权限
   - 后台下载权限

2. 内存管理
   - 大文件下载使用分片下载
   - 及时清理临时文件
   - 监控内存使用情况

3. 磁盘管理
   - 定期检查磁盘空间
   - 及时清理已完成的下载
   - 注意文件合并时的空间需求

4. 网络管理
   - 注意网络类型限制
   - 合理设置超时时间
   - 处理网络切换情况

## 示例代码

### 1. 基本下载示例

```swift
// 创建下载管理器
let downloadManager = DownloadManager.shared

// 配置下载管理器
let configuration = DownloadManagerConfiguration(
    maxConcurrentDownloads: 3,
    allowCellularDownloads: true
)
downloadManager.configure(configuration)

// 创建下载任务
let url = URL(string: "https://example.com/file.zip")!
let destinationURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("file.zip")

let task = try downloadManager.createDownloadTask(
    url: url,
    destinationURL: destinationURL,
    configuration: DefaultDownloadTaskConfiguration()
)

// 监听下载进度
task.progressPublisher
    .sink { progress in
        print("下载进度: \(progress)")
    }
    .store(in: &cancellables)

// 开始下载
task.resume()
```

### 2. 批量下载示例

```swift
// 创建批量下载任务
let urls = [
    URL(string: "https://example.com/file1.zip")!,
    URL(string: "https://example.com/file2.zip")!,
    URL(string: "https://example.com/file3.zip")!
]

let destinationDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Downloads")

let batchTask = try downloadManager.createBatchDownload(
    urls: urls,
    destinationDirectory: destinationDirectory,
    configuration: DefaultDownloadTaskConfiguration()
)

// 开始批量下载
downloadManager.startBatchDownload(batchId: batchTask.batchId)

// 获取批量下载任务
if let task = downloadManager.getBatchTask(batchId: batchTask.batchId) {
    print("总任务数: \(task.totalCount)")
    print("成功任务数: \(task.successCount)")
    print("失败任务数: \(task.failedCount)")
    print("下载进度: \(task.progress)")
}
```

### 3. 高级配置示例

```swift
// 创建高级下载配置
let configuration = DefaultDownloadTaskConfiguration(
    timeoutInterval: 30,
    headers: [
        "Authorization": "Bearer token",
        "User-Agent": "PanPlayer/1.0"
    ],
    chunkSize: 1024 * 1024, // 1MB
    maxConcurrentChunks: 3,
    speedLimit: 1024 * 1024, // 1MB/s
    priority: 100,
    allowsBackgroundDownload: true,
    allowsCellularAccess: false,
    allowsConstrainedNetworkAccess: true,
    allowsExpensiveNetworkAccess: true
)

// 创建下载任务
let task = try downloadManager.createDownloadTask(
    url: url,
    destinationURL: destinationURL,
    configuration: configuration
)

// 设置任务优先级
downloadManager.setTaskPriority(100, forTaskWithIdentifier: task.identifier)

// 开始下载
task.resume()
```

## 后台下载

DownloadManager 支持在应用后台继续下载文件，主要功能包括：

### 1. 配置后台下载

在应用启动时配置后台下载：

```swift
// 配置后台下载
BackgroundDownloadHandler.shared.configure()

// 设置自定义的完成处理程序
BackgroundDownloadHandler.shared.setCompletionHandler {
    // 自定义的完成处理逻辑
    print("后台下载完成")
}
```

### 2. 创建后台下载任务

```swift
// 创建后台下载任务
let task = try downloadManager.createBackgroundDownloadTask(
    url: url,
    destinationURL: destinationURL,
    configuration: configuration
)

// 监听下载进度
task.progressPublisher
    .sink { progress in
        print("下载进度: \(progress)")
    }
    .store(in: &cancellables)

// 监听下载状态
task.statePublisher
    .sink { state in
        print("下载状态: \(state)")
    }
    .store(in: &cancellables)
```

### 3. 后台下载配置

在 Info.plist 中添加以下配置：

```xml
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
    <string>processing</string>
</array>
```

### 4. 通知管理

后台下载完成时会自动发送本地通知，包括：

- 下载完成通知
- 应用图标角标更新
- 声音提醒

### 5. 注意事项

1. 后台下载限制
   - 系统可能会限制后台下载时间
   - 网络状态变化可能影响下载
   - 电池电量可能影响下载

2. 内存管理
   - 后台下载时注意内存使用
   - 及时清理临时文件
   - 避免大量并发下载

3. 网络管理
   - 注意网络类型限制
   - 处理网络切换
   - 处理网络断开

4. 存储管理
   - 检查磁盘空间
   - 管理临时文件
   - 处理文件合并

## 安装

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/DownloadManager.git", from: "1.0.0")
]
```

## 贡献

欢迎提交 Issue 和 Pull Request。

## 许可证

MIT License