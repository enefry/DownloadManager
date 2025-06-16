import XCTest
@testable import DownloadManager

final class ChunkDownloadManagerTests: XCTestCase {
    var downloadManager: ChunkDownloadManager!
    var mockDelegate: MockChunkDownloadManagerDelegate!
    var mockURLSession: MockURLSession!
    var mockDownloadTask: DownloadTask!
    var configuration: ChunkConfiguration!

    override func setUp() {
        super.setUp()

        // 创建测试配置
        let taskConfig = DownloadTaskConfiguration(
            timeoutInterval: 30,
            headers: [:]
        )

        configuration = ChunkConfiguration(
            chunkSize: 1024 * 1024, // 1MB
            maxConcurrentChunks: 3,
            timeoutInterval: 30,
            taskConfigure: taskConfig
        )

        // 创建模拟的下载任务
        mockDownloadTask = DownloadTask(
            url: URL(string: "https://example.com/test.file")!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent("test.file"),
            configuration: taskConfig,
            session: URLSession.shared
        )

        // 创建模拟的 URLSession
        mockURLSession = MockURLSession()

        // 创建模拟的代理
        mockDelegate = MockChunkDownloadManagerDelegate()

        // 创建下载管理器
        downloadManager = ChunkDownloadManager(
            downloadTask: mockDownloadTask,
            configuration: configuration,
            delegate: mockDelegate,
            session: mockURLSession
        )
    }

    override func tearDown() {
        // 清理临时文件
        try? FileManager.default.removeItem(at: mockDownloadTask.destinationURL)
        downloadManager = nil
        mockDelegate = nil
        mockURLSession = nil
        mockDownloadTask = nil
        configuration = nil
        super.tearDown()
    }

    // MARK: - 测试用例

    func testServerSupportCheck() {
        // 准备模拟响应
        let mockResponse = HTTPURLResponse(
            url: mockDownloadTask.url,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Length": "10485760"] // 10MB
        )!
        mockURLSession.mockResponse = mockResponse

        // 开始下载
        downloadManager.start()

        // 验证 HEAD 请求
        XCTAssertEqual(mockURLSession.lastRequest?.httpMethod, "HEAD")
        XCTAssertEqual(mockURLSession.lastRequest?.value(forHTTPHeaderField: "Range"), "bytes=0-1")

        // 验证代理回调
        XCTAssertTrue(mockDelegate.didUpdateProgress)
        XCTAssertEqual(mockDelegate.lastProgress, 0.0)
    }

    func testChunkDownload() {
        // 准备模拟响应
        let mockResponse = HTTPURLResponse(
            url: mockDownloadTask.url,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Length": "10485760"] // 10MB
        )!
        mockURLSession.mockResponse = mockResponse

        // 模拟分片数据
        let chunkData = Data(repeating: 0, count: 1024 * 1024) // 1MB
        mockURLSession.mockData = chunkData

        // 开始下载
        downloadManager.start()

        // 验证分片请求
        XCTAssertEqual(mockURLSession.lastRequest?.value(forHTTPHeaderField: "Range"), "bytes=0-1048575")

        // 验证进度更新
        XCTAssertTrue(mockDelegate.didUpdateProgress)
    }

    func testResumeDownload() {
        // 准备模拟响应
        let mockResponse = HTTPURLResponse(
            url: mockDownloadTask.url,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Length": "10485760"] // 10MB
        )!
        mockURLSession.mockResponse = mockResponse

        // 创建部分下载的分片文件
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadManager")
            .appendingPathComponent(mockDownloadTask.identifier)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let chunkPath = tempDir.appendingPathComponent("0_1048576")
        let partialData = Data(repeating: 0, count: 512 * 1024) // 512KB
        try? partialData.write(to: chunkPath)

        // 开始下载
        downloadManager.start()

        // 验证断点续传请求
        XCTAssertEqual(mockURLSession.lastRequest?.value(forHTTPHeaderField: "Range"), "bytes=524288-1048575")
    }

    func testErrorHandling() {
        // 准备模拟错误
        let mockError = DownloadError.networkError("测试错误")
        mockURLSession.mockError = mockError

        // 开始下载
        downloadManager.start()

        // 验证错误处理
        XCTAssertTrue(mockDelegate.didFailWithError)
        XCTAssertEqual(mockDelegate.lastError?.localizedDescription, mockError.localizedDescription)
    }

    func testProgressUpdate() {
        // 准备模拟响应
        let mockResponse = HTTPURLResponse(
            url: mockDownloadTask.url,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Length": "10485760"] // 10MB
        )!
        mockURLSession.mockResponse = mockResponse

        // 模拟分片数据
        let chunkData = Data(repeating: 0, count: 1024 * 1024) // 1MB
        mockURLSession.mockData = chunkData

        // 开始下载
        downloadManager.start()

        // 验证进度更新
        XCTAssertTrue(mockDelegate.didUpdateProgress)
        XCTAssertGreaterThan(mockDelegate.lastProgress, 0.0)
        XCTAssertLessThanOrEqual(mockDelegate.lastProgress, 1.0)
    }

    func testPauseAndResume() {
        // 准备模拟响应
        let mockResponse = HTTPURLResponse(
            url: mockDownloadTask.url,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Length": "10485760"] // 10MB
        )!
        mockURLSession.mockResponse = mockResponse

        // 开始下载
        downloadManager.start()

        // 暂停下载
        downloadManager.pause()

        // 验证任务是否被暂停
        XCTAssertEqual(mockURLSession.lastTask?.state, .suspended)

        // 恢复下载
        downloadManager.resume()

        // 验证任务是否被恢复
        XCTAssertEqual(mockURLSession.lastTask?.state, .running)
    }

    func testCancel() {
        // 准备模拟响应
        let mockResponse = HTTPURLResponse(
            url: mockDownloadTask.url,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Length": "10485760"] // 10MB
        )!
        mockURLSession.mockResponse = mockResponse

        // 开始下载
        downloadManager.start()

        // 取消下载
        downloadManager.cancel()

        // 验证任务是否被取消
        XCTAssertEqual(mockURLSession.lastTask?.state, .canceling)

        // 验证临时文件是否被清理
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadManager")
            .appendingPathComponent(mockDownloadTask.identifier)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
    }

    func testChunkMerge() {
        // 准备模拟响应
        let mockResponse = HTTPURLResponse(
            url: mockDownloadTask.url,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Length": "10485760"] // 10MB
        )!
        mockURLSession.mockResponse = mockResponse

        // 模拟分片数据
        let chunkData = Data(repeating: 0, count: 1024 * 1024) // 1MB
        mockURLSession.mockData = chunkData

        // 开始下载
        downloadManager.start()

        // 等待所有分片下载完成
        let expectation = XCTestExpectation(description: "等待下载完成")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3)

        // 验证最终文件是否存在
        XCTAssertTrue(FileManager.default.fileExists(atPath: mockDownloadTask.destinationURL.path))

        // 验证文件大小
        let attributes = try? FileManager.default.attributesOfItem(atPath: mockDownloadTask.destinationURL.path)
        let fileSize = attributes?[.size] as? Int64 ?? 0
        XCTAssertEqual(fileSize, 10485760) // 10MB
    }

    func testConcurrentChunks() {
        // 准备模拟响应
        let mockResponse = HTTPURLResponse(
            url: mockDownloadTask.url,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Length": "10485760"] // 10MB
        )!
        mockURLSession.mockResponse = mockResponse

        // 模拟分片数据
        let chunkData = Data(repeating: 0, count: 1024 * 1024) // 1MB
        mockURLSession.mockData = chunkData

        // 开始下载
        downloadManager.start()

        // 验证并发下载任务数
        let expectation = XCTestExpectation(description: "等待并发任务")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            XCTAssertLessThanOrEqual(self.mockURLSession.activeTasksCount, self.configuration.maxConcurrentChunks)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testRetryMechanism() {
        // 准备模拟错误
        let mockError = DownloadError.networkError("测试错误")
        mockURLSession.mockError = mockError

        // 开始下载
        downloadManager.start()

        // 验证重试机制
        let expectation = XCTestExpectation(description: "等待重试")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            XCTAssertEqual(self.mockURLSession.retryCount, 3) // 最大重试次数
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3)
    }
}

// MARK: - 模拟类

final class MockChunkDownloadManagerDelegate: ChunkDownloadManagerDelegate {
    var didUpdateProgress = false
    var lastProgress: Double = 0.0
    var didFailWithError = false
    var lastError: Error?
    var didCompleteWithURL = false
    var lastURL: URL?

    func chunkDownloadManager(_ manager: ChunkDownloadManager, didUpdateProgress progress: Double) {
        didUpdateProgress = true
        lastProgress = progress
    }

    func chunkDownloadManager(_ manager: ChunkDownloadManager, didUpdateState state: DownloadState) {
        // 测试中暂不使用
    }

    func chunkDownloadManager(_ manager: ChunkDownloadManager, didCompleteWithURL url: URL) {
        didCompleteWithURL = true
        lastURL = url
    }

    func chunkDownloadManager(_ manager: ChunkDownloadManager, didFailWithError error: Error) {
        didFailWithError = true
        lastError = error
    }
}

final class MockURLSession: URLSession {
    var mockResponse: HTTPURLResponse?
    var mockData: Data?
    var mockError: Error?
    var lastRequest: URLRequest?
    var lastTask: MockURLSessionTask?
    var activeTasksCount: Int = 0
    var retryCount: Int = 0

    override func dataTask(with request: URLRequest, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        lastRequest = request
        activeTasksCount += 1
        let task = MockURLSessionDataTask { [weak self] in
            guard let self = self else { return }
            self.activeTasksCount -= 1
            if let error = self.mockError {
                self.retryCount += 1
            }
            completionHandler(self.mockData, self.mockResponse, self.mockError)
        }
        lastTask = task
        return task
    }

    override func downloadTask(with request: URLRequest, completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void) -> URLSessionDownloadTask {
        lastRequest = request
        activeTasksCount += 1
        let task = MockURLSessionDownloadTask { [weak self] in
            guard let self = self else { return }
            self.activeTasksCount -= 1
            if let data = self.mockData {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try? data.write(to: tempURL)
                completionHandler(tempURL, self.mockResponse, self.mockError)
            } else {
                completionHandler(nil, self.mockResponse, self.mockError)
            }
        }
        lastTask = task
        return task
    }
}

class MockURLSessionTask: URLSessionTask {
    private var _state: URLSessionTask.State = .running

    override var state: URLSessionTask.State {
        return _state
    }

    func setState(_ newState: URLSessionTask.State) {
        _state = newState
    }
}

final class MockURLSessionDataTask: MockURLSessionTask {
    private let completion: () -> Void

    init(completion: @escaping () -> Void) {
        self.completion = completion
        super.init()
    }

    override func resume() {
        completion()
    }

    override func suspend() {
        setState(.suspended)
    }

    override func cancel() {
        setState(.canceling)
    }
}

final class MockURLSessionDownloadTask: MockURLSessionTask {
    private let completion: () -> Void

    init(completion: @escaping () -> Void) {
        self.completion = completion
        super.init()
    }

    override func resume() {
        completion()
    }

    override func suspend() {
        setState(.suspended)
    }

    override func cancel() {
        setState(.canceling)
    }
}