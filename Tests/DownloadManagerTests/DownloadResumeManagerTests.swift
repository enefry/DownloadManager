import XCTest
@testable import DownloadManager

final class ChunkDownloadManagerTests: XCTestCase {
    var resumeManager: ChunkDownloadManager!
    var mockSession: MockURLSession!
    let testURL = URL(string: "https://example.com/test.file")!
    let testDestinationURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test.file")

    override func setUp() {
        super.setUp()
        mockSession = MockURLSession()
        resumeManager = ChunkDownloadManager(session: mockSession)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDestinationURL)
        resumeManager = nil
        mockSession = nil
        super.tearDown()
    }

    // MARK: - 测试断点续传支持检查

    func testCheckResumeSupport() async throws {
        // 配置模拟响应
        mockSession.mockResponse = HTTPURLResponse(
            url: testURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Accept-Ranges": "bytes"]
        )

        // 测试支持断点续传
        let supportsResume = try await resumeManager.checkResumeSupport(for: testURL)
        XCTAssertTrue(supportsResume)

        // 配置不支持断点续传的响应
        mockSession.mockResponse = HTTPURLResponse(
            url: testURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [:]
        )

        // 测试不支持断点续传
        let notSupportsResume = try await resumeManager.checkResumeSupport(for: testURL)
        XCTAssertFalse(notSupportsResume)
    }

    // MARK: - 测试文件大小获取

    func testGetFileSize() async throws {
        // 配置模拟响应
        mockSession.mockResponse = HTTPURLResponse(
            url: testURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "1000000"]
        )

        // 测试获取文件大小
        let fileSize = try await resumeManager.getFileSize(for: testURL)
        XCTAssertEqual(fileSize, 1000000)
    }

    // MARK: - 测试分片下载

    func testChunkDownload() async throws {
        // 配置模拟响应
        let fileSize: Int64 = 1000000
        let chunkSize: Int64 = 100000
        let configuration = ChunkConfiguration(
            chunkSize: chunkSize,
            maxConcurrentChunks: 3,
            timeoutInterval: 30
        )

        // 模拟分片数据
        let mockData = Data(repeating: 0, count: Int(chunkSize))
        mockSession.mockData = mockData
        mockSession.mockResponse = HTTPURLResponse(
            url: testURL,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Length": "\(chunkSize)"]
        )

        // 创建期望
        let expectation = XCTestExpectation(description: "分片下载完成")

        // 开始分片下载
        resumeManager.startChunkDownload(
            url: testURL,
            fileSize: fileSize,
            configuration: configuration,
            progressHandler: { progress in
                // 验证进度更新
                XCTAssertGreaterThanOrEqual(progress, 0)
                XCTAssertLessThanOrEqual(progress, 1)
            },
            completionHandler: { result in
                switch result {
                case .success(let url):
                    // 验证文件大小
                    let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
                    XCTAssertEqual(fileSize, 1000000)
                case .failure(let error):
                    XCTFail("下载失败: \(error)")
                }
                expectation.fulfill()
            }
        )

        // 等待下载完成
        wait(for: [expectation], timeout: 5)
    }

    // MARK: - 测试分片断点续传

    func testChunkResume() async throws {
        // 配置模拟响应
        let fileSize: Int64 = 1000000
        let chunkSize: Int64 = 100000
        let configuration = ChunkConfiguration(
            chunkSize: chunkSize,
            maxConcurrentChunks: 3,
            timeoutInterval: 30
        )

        // 创建部分下载的分片文件
        let taskId = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadManager")
            .appendingPathComponent(taskId)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let chunkFileURL = tempDir.appendingPathComponent("chunk_0")
        let partialData = Data(repeating: 0, count: Int(chunkSize / 2))
        try partialData.write(to: chunkFileURL)

        // 模拟剩余分片数据
        let remainingData = Data(repeating: 0, count: Int(chunkSize / 2))
        mockSession.mockData = remainingData
        mockSession.mockResponse = HTTPURLResponse(
            url: testURL,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Length": "\(chunkSize / 2)"]
        )

        // 创建期望
        let expectation = XCTestExpectation(description: "分片续传完成")

        // 开始分片下载
        resumeManager.startChunkDownload(
            url: testURL,
            fileSize: fileSize,
            configuration: configuration,
            progressHandler: { progress in
                // 验证进度更新
                XCTAssertGreaterThanOrEqual(progress, 0)
                XCTAssertLessThanOrEqual(progress, 1)
            },
            completionHandler: { result in
                switch result {
                case .success(let url):
                    // 验证文件大小
                    let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
                    XCTAssertEqual(fileSize, 1000000)
                case .failure(let error):
                    XCTFail("下载失败: \(error)")
                }
                expectation.fulfill()
            }
        )

        // 等待下载完成
        wait(for: [expectation], timeout: 5)

        // 清理临时文件
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 测试分片下载暂停和恢复

    func testChunkPauseAndResume() async throws {
        // 配置模拟响应
        let fileSize: Int64 = 1000000
        let chunkSize: Int64 = 100000
        let configuration = ChunkConfiguration(
            chunkSize: chunkSize,
            maxConcurrentChunks: 3,
            timeoutInterval: 30
        )

        // 模拟分片数据
        let mockData = Data(repeating: 0, count: Int(chunkSize))
        mockSession.mockData = mockData
        mockSession.mockResponse = HTTPURLResponse(
            url: testURL,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Length": "\(chunkSize)"]
        )

        // 创建期望
        let downloadExpectation = XCTestExpectation(description: "分片下载开始")
        let pauseExpectation = XCTestExpectation(description: "分片下载暂停")
        let resumeExpectation = XCTestExpectation(description: "分片下载恢复")

        var taskId: String?

        // 开始分片下载
        resumeManager.startChunkDownload(
            url: testURL,
            fileSize: fileSize,
            configuration: configuration,
            progressHandler: { progress in
                // 验证进度更新
                XCTAssertGreaterThanOrEqual(progress, 0)
                XCTAssertLessThanOrEqual(progress, 1)
            },
            completionHandler: { result in
                switch result {
                case .success(let url):
                    // 验证文件大小
                    let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
                    XCTAssertEqual(fileSize, 1000000)
                case .failure(let error):
                    XCTFail("下载失败: \(error)")
                }
                resumeExpectation.fulfill()
            }
        )

        // 等待下载开始
        downloadExpectation.fulfill()

        // 暂停下载
        if let id = taskId {
            resumeManager.pauseChunkDownload(taskId: id)
            pauseExpectation.fulfill()

            // 恢复下载
            resumeManager.resumeChunkDownload(
                taskId: id,
                url: testURL,
                configuration: configuration,
                progressHandler: { progress in
                    // 验证进度更新
                    XCTAssertGreaterThanOrEqual(progress, 0)
                    XCTAssertLessThanOrEqual(progress, 1)
                },
                completionHandler: { result in
                    switch result {
                    case .success(let url):
                        // 验证文件大小
                        let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
                        XCTAssertEqual(fileSize, 1000000)
                    case .failure(let error):
                        XCTFail("下载失败: \(error)")
                    }
                    resumeExpectation.fulfill()
                }
            )
        }

        // 等待所有操作完成
        wait(for: [downloadExpectation, pauseExpectation, resumeExpectation], timeout: 5)
    }

    // MARK: - 测试分片下载取消

    func testChunkCancel() async throws {
        // 配置模拟响应
        let fileSize: Int64 = 1000000
        let chunkSize: Int64 = 100000
        let configuration = ChunkConfiguration(
            chunkSize: chunkSize,
            maxConcurrentChunks: 3,
            timeoutInterval: 30
        )

        // 模拟分片数据
        let mockData = Data(repeating: 0, count: Int(chunkSize))
        mockSession.mockData = mockData
        mockSession.mockResponse = HTTPURLResponse(
            url: testURL,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Length": "\(chunkSize)"]
        )

        // 创建期望
        let downloadExpectation = XCTestExpectation(description: "分片下载开始")
        let cancelExpectation = XCTestExpectation(description: "分片下载取消")

        var taskId: String?

        // 开始分片下载
        resumeManager.startChunkDownload(
            url: testURL,
            fileSize: fileSize,
            configuration: configuration,
            progressHandler: { progress in
                // 验证进度更新
                XCTAssertGreaterThanOrEqual(progress, 0)
                XCTAssertLessThanOrEqual(progress, 1)
            },
            completionHandler: { result in
                switch result {
                case .success:
                    XCTFail("下载不应该成功")
                case .failure(let error):
                    XCTAssertTrue(error is DownloadError)
                }
                cancelExpectation.fulfill()
            }
        )

        // 等待下载开始
        downloadExpectation.fulfill()

        // 取消下载
        if let id = taskId {
            resumeManager.cancelChunkDownload(taskId: id)
        }

        // 等待所有操作完成
        wait(for: [downloadExpectation, cancelExpectation], timeout: 5)
    }
}

// MARK: - Mock URLSession

class MockURLSession: URLSession {
    var mockData: Data?
    var mockResponse: HTTPURLResponse?
    var mockError: Error?

    override func dataTask(
        with request: URLRequest,
        completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTask {
        return MockURLSessionDataTask(
            request: request,
            completionHandler: completionHandler,
            mockData: mockData,
            mockResponse: mockResponse,
            mockError: mockError
        )
    }
}

class MockURLSessionDataTask: URLSessionDataTask {
    private let request: URLRequest
    private let completionHandler: (Data?, URLResponse?, Error?) -> Void
    private let mockData: Data?
    private let mockResponse: HTTPURLResponse?
    private let mockError: Error?

    init(
        request: URLRequest,
        completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void,
        mockData: Data?,
        mockResponse: HTTPURLResponse?,
        mockError: Error?
    ) {
        self.request = request
        self.completionHandler = completionHandler
        self.mockData = mockData
        self.mockResponse = mockResponse
        self.mockError = mockError
        super.init()
    }

    override func resume() {
        completionHandler(mockData, mockResponse, mockError)
    }

    override func cancel() {
        completionHandler(nil, nil, DownloadError.cancelled)
    }
}
