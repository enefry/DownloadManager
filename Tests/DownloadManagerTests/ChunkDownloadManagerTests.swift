@testable import DownloadManager
import XCTest

final class ChunkDownloadManagerTests: XCTestCase {
    // MARK: - Test Properties

    private var downloadManager: ChunkDownloadManager!
    private var mockDelegate: MockChunkDownloadManagerDelegate!
    private var mockDownloadTask: DownloadTask!
    private var downloadTaskConfiguration: DownloadTaskConfiguration!
    private var mockConfiguration: ChunkConfiguration!

    private var mockSession: URLSession!
    private let testURL = URL(string: "https://example.com/test.file")!
    private let testData = "Test data".data(using: .utf8)!

    // MARK: - Test Setup

    override func setUp() {
        super.setUp()

        // 注册 MockURLProtocol
        URLProtocol.registerClass(MockURLProtocol.self)
        downloadTaskConfiguration = DownloadTaskConfiguration(timeoutInterval: 10)
        // Create mock download task
        mockDownloadTask = DownloadTask(
            url: testURL,
            destinationURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test.file"), configuration: downloadTaskConfiguration
        )

        // Create mock configuration
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]

        mockConfiguration = ChunkConfiguration(
            chunkSize: 1024 * 1024, // 1MB
            maxConcurrentChunks: 3,
            timeoutInterval: 30,
            taskConfigure: DownloadTaskConfiguration(headers: [:]),
            sessionConfigure: sessionConfig
        )

        // Create mock delegate
        mockDelegate = MockChunkDownloadManagerDelegate()

        // Create URLSession with mock configuration
        mockSession = URLSession(configuration: mockConfiguration.sessionConfigure)

        // Create download manager
        downloadManager = ChunkDownloadManager(
            downloadTask: mockDownloadTask,
            configuration: mockConfiguration,
            delegate: mockDelegate
        )

        // 设置默认的模拟响应
        setupDefaultMockResponse()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        downloadManager = nil
        mockDelegate = nil
        mockDownloadTask = nil
        mockConfiguration = nil
        mockSession = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func setupDefaultMockResponse() {
        // 设置 HEAD 请求的响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL)

        // 设置 GET 请求的响应
        let getResponse = MockURLProtocol.MockResponse(
            data: testData,
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: getResponse, for: testURL)
    }

    // MARK: - Test Cases

    func testInitialization() {
        XCTAssertNotNil(downloadManager)
        XCTAssertEqual(mockDelegate.stateUpdates.count, 1)
        XCTAssertEqual(mockDelegate.stateUpdates.first, .waiting)
    }

    func testStartDownload() {
        // Given
        let expectation = XCTestExpectation(description: "Download should start")
        mockDelegate.completionExpectation = expectation

        // When
        downloadManager.start()

        // Then
        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(mockDelegate.stateUpdates.last, .preparing)
    }

    func testPauseAndResume() {
        // Given
        let startExpectation = XCTestExpectation(description: "Download should start")
        let pauseExpectation = XCTestExpectation(description: "Download should pause")
        let resumeExpectation = XCTestExpectation(description: "Download should resume")

        mockDelegate.completionExpectation = startExpectation

        // When
        downloadManager.start()
        wait(for: [startExpectation], timeout: 5.0)

        downloadManager.pause()
        XCTAssertEqual(mockDelegate.stateUpdates.last, .paused)

        downloadManager.resume()
        XCTAssertEqual(mockDelegate.stateUpdates.last, .downloading)
    }

    func testCancel() {
        // Given
        let startExpectation = XCTestExpectation(description: "Download should start")
        mockDelegate.completionExpectation = startExpectation

        // When
        downloadManager.start()
        wait(for: [startExpectation], timeout: 5.0)

        downloadManager.cancel()

        // Then
        XCTAssertEqual(mockDelegate.stateUpdates.last, .cancelled)
    }

    func testProgressUpdates() {
        // Given
        let progressExpectation = XCTestExpectation(description: "Progress should be updated")
        mockDelegate.progressExpectation = progressExpectation

        // When
        downloadManager.start()

        // Then
        wait(for: [progressExpectation], timeout: 5.0)
        XCTAssertGreaterThanOrEqual(mockDelegate.progressUpdates.count, 1)
        XCTAssertLessThanOrEqual(mockDelegate.progressUpdates.last ?? 0, 1.0)
    }

    func testErrorHandling() {
        // Given
        let errorExpectation = XCTestExpectation(description: "Error should be handled")
        mockDelegate.errorExpectation = errorExpectation

        // 设置模拟错误响应
        let errorResponse = MockURLProtocol.MockResponse(
            statusCode: 404,
            error: NSError(domain: "TestError", code: 404, userInfo: nil)
        )
        MockURLProtocol.register(mockResponse: errorResponse, for: testURL)

        // When
        downloadManager.start()

        // Then
        wait(for: [errorExpectation], timeout: 5.0)
        XCTAssertNotNil(mockDelegate.lastError)
    }

    func testChunkDownload() {
        // Given
        let completionExpectation = XCTestExpectation(description: "Download should complete")
        mockDelegate.completionExpectation = completionExpectation

        // 设置支持分片下载的响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL)

        // When
        downloadManager.start()

        // Then
        wait(for: [completionExpectation], timeout: 5.0)
        XCTAssertEqual(mockDelegate.stateUpdates.last, .completed)
        XCTAssertNotNil(mockDelegate.completionURL)
    }

    func testServerNotSupportingRanges() {
        // Given
        let errorExpectation = XCTestExpectation(description: "Should handle server not supporting ranges")
        mockDelegate.errorExpectation = errorExpectation

        // 设置不支持分片下载的响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL)

        // When
        downloadManager.start()

        // Then
        wait(for: [errorExpectation], timeout: 5.0)
        XCTAssertNotNil(mockDelegate.lastError)
        if let error = mockDelegate.lastError as? ChunkDownloadError {
            XCTAssertEqual(error.errorCode, ChunkDownloadError.serverNotSupported.errorCode)
        }
    }

    func testLargeFileChunkDownload() {
        // Given
        let completionExpectation = XCTestExpectation(description: "Large file download should complete")
        mockDelegate.completionExpectation = completionExpectation

        // 创建一个 10MB 的测试数据
        let largeData = Data(count: 10 * 1024 * 1024)

        // 设置支持分片下载的响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(largeData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL)

        // 设置 GET 请求的响应
        let getResponse = MockURLProtocol.MockResponse(
            data: largeData,
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(largeData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: getResponse, for: testURL)

        // When
        downloadManager.start()

        // Then
        wait(for: [completionExpectation], timeout: 30.0)
        XCTAssertEqual(mockDelegate.stateUpdates.last, .completed)
        XCTAssertNotNil(mockDelegate.completionURL)

        // 验证文件大小
        if let url = mockDelegate.completionURL {
            let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
            XCTAssertEqual(fileSize, Int64(largeData.count))
        }
    }

    func testNetworkTimeout() {
        // Given
        let errorExpectation = XCTestExpectation(description: "Should handle network timeout")
        mockDelegate.errorExpectation = errorExpectation

        // 设置超时响应
        let timeoutResponse = MockURLProtocol.MockResponse(
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil), delay: 31.0
        )
        MockURLProtocol.register(mockResponse: timeoutResponse, for: testURL)

        // When
        downloadManager.start()

        // Then
        wait(for: [errorExpectation], timeout: 35.0)
        XCTAssertNotNil(mockDelegate.lastError)
        if let error = mockDelegate.lastError as? ChunkDownloadError {
            XCTAssertEqual(error.errorCode, ChunkDownloadError.timeout.errorCode)
        }
    }

    func testPartialChunkFailure() {
        // Given
        let errorExpectation = XCTestExpectation(description: "Should handle partial chunk failure")
        mockDelegate.errorExpectation = errorExpectation

        // 创建一个 5MB 的测试数据
        let testData = Data(count: 5 * 1024 * 1024)

        // 设置 HEAD 响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL)

        // 设置第一个分片的响应（成功）
        let firstChunkResponse = MockURLProtocol.MockResponse(
            data: testData.prefix(1024 * 1024), // 第一个 1MB
            statusCode: 206,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes 0-1048575/\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: firstChunkResponse, for: testURL)

        // 设置第二个分片的响应（失败）
        let secondChunkResponse = MockURLProtocol.MockResponse(
            statusCode: 500,
            error: NSError(domain: "TestError", code: 500, userInfo: nil)
        )
        MockURLProtocol.register(mockResponse: secondChunkResponse, for: testURL)

        // When
        downloadManager.start()

        // Then
        wait(for: [errorExpectation], timeout: 10.0)
        XCTAssertNotNil(mockDelegate.lastError)
    }

    func testResumeDownload() {
        // Given
        let completionExpectation = XCTestExpectation(description: "Download should resume and complete")
        mockDelegate.completionExpectation = completionExpectation

        // 创建一个 3MB 的测试数据
        let testData = Data(count: 3 * 1024 * 1024)

        // 设置 HEAD 响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL)

        // 设置第一个分片的响应（成功）
        let firstChunkResponse = MockURLProtocol.MockResponse(
            data: testData.prefix(1024 * 1024), // 第一个 1MB
            statusCode: 206,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes 0-1048575/\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: firstChunkResponse, for: testURL)

        // 设置第二个分片的响应（成功）
        let secondChunkResponse = MockURLProtocol.MockResponse(
            data: testData.subdata(in: 1024 * 1024 ..< 2 * 1024 * 1024), // 第二个 1MB
            statusCode: 206,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes 1048576-2097151/\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: secondChunkResponse, for: testURL)

        // 设置第三个分片的响应（成功）
        let thirdChunkResponse = MockURLProtocol.MockResponse(
            data: testData.subdata(in: 2 * 1024 * 1024 ..< 3 * 1024 * 1024), // 第三个 1MB
            statusCode: 206,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes 2097152-3145727/\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: thirdChunkResponse, for: testURL)

        // When
        downloadManager.start()

        // 等待第一个分片下载完成
        Thread.sleep(forTimeInterval: 1.0)

        // 暂停下载
        downloadManager.pause()
        XCTAssertEqual(mockDelegate.stateUpdates.last, .paused)

        // 恢复下载
        downloadManager.resume()
        XCTAssertEqual(mockDelegate.stateUpdates.last, .downloading)

        // Then
        wait(for: [completionExpectation], timeout: 10.0)
        XCTAssertEqual(mockDelegate.stateUpdates.last, .completed)
        XCTAssertNotNil(mockDelegate.completionURL)

        // 验证文件大小
        if let url = mockDelegate.completionURL {
            let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
            XCTAssertEqual(fileSize, Int64(testData.count))
        }
    }

    func testConcurrentChunkDownload() {
        // Given
        let completionExpectation = XCTestExpectation(description: "Concurrent chunk download should complete")
        mockDelegate.completionExpectation = completionExpectation

        // 创建一个 6MB 的测试数据
        let testData = Data(count: 6 * 1024 * 1024)

        // 设置 HEAD 响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL)

        // 设置每个分片的响应
        for i in 0 ..< 6 {
            let start = i * 1024 * 1024
            let end = min((i + 1) * 1024 * 1024 - 1, testData.count - 1)
            let chunkData = testData.subdata(in: start ..< end + 1)

            let chunkResponse = MockURLProtocol.MockResponse(
                data: chunkData,
                statusCode: 206,
                headers: [
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes \(start)-\(end)/\(testData.count)",
                ]
            )
            MockURLProtocol.register(mockResponse: chunkResponse, for: testURL)
        }

        // When
        downloadManager.start()

        // Then
        wait(for: [completionExpectation], timeout: 10.0)
        XCTAssertEqual(mockDelegate.stateUpdates.last, .completed)
        XCTAssertNotNil(mockDelegate.completionURL)

        // 验证文件大小
        if let url = mockDelegate.completionURL {
            let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
            XCTAssertEqual(fileSize, Int64(testData.count))
        }
    }

    func testInsufficientDiskSpace() {
        // Given
        let errorExpectation = XCTestExpectation(description: "Should handle insufficient disk space")
        mockDelegate.errorExpectation = errorExpectation

        // 创建一个 100GB 的测试数据（模拟大文件）
        let largeData = Data(count: 100 * 1024 * 1024 * 1024)

        // 设置 HEAD 响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(largeData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL)

        // When
        downloadManager.start()

        // Then
        wait(for: [errorExpectation], timeout: 5.0)
        XCTAssertNotNil(mockDelegate.lastError)
        if let error = mockDelegate.lastError as? ChunkDownloadError {
            XCTAssertEqual(error.errorCode, ChunkDownloadError.insufficientDiskSpace.errorCode)
        }
    }

    // MARK: - Additional Test Cases

    func testInvalidResponseHeaders() {
        // Given
        let errorExpectation = XCTestExpectation(description: "Should handle invalid response headers")
        mockDelegate.errorExpectation = errorExpectation

        // 设置无效的响应头（缺少必要的 Content-Length）
        let invalidResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                // 故意不设置 Content-Length
            ]
        )
        MockURLProtocol.register(mockResponse: invalidResponse, for: testURL)

        // When
        downloadManager.start()

        // Then
        wait(for: [errorExpectation], timeout: 5.0)
        XCTAssertNotNil(mockDelegate.lastError)
        if let error = mockDelegate.lastError as? ChunkDownloadError {
            XCTAssertEqual(error.errorCode, ChunkDownloadError.invalidResponse.errorCode)
        }
    }

    func testCorruptedChunkData() {
        // Given
        let errorExpectation = XCTestExpectation(description: "Should handle corrupted chunk data")
        mockDelegate.errorExpectation = errorExpectation

        // 创建一个 3MB 的测试数据
        let testData = Data(count: 3 * 1024 * 1024)

        // 设置 HEAD 响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL)

        // 设置第一个分片的响应（数据不完整）
        let firstChunkResponse = MockURLProtocol.MockResponse(
            data: testData.prefix(512 * 1024), // 只返回一半的数据
            statusCode: 206,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes 0-1048575/\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: firstChunkResponse, for: testURL)

        // When
        downloadManager.start()

        // Then
        wait(for: [errorExpectation], timeout: 5.0)
        XCTAssertNotNil(mockDelegate.lastError)
        if let error = mockDelegate.lastError as? ChunkDownloadError {
            XCTAssertEqual(error.errorCode, ChunkDownloadError.corruptedChunk(0).errorCode)
        }
    }

    func testMultiplePauseResume() {
        // Given
        let completionExpectation = XCTestExpectation(description: "Download should complete after multiple pauses")
        mockDelegate.completionExpectation = completionExpectation

        // 创建一个 4MB 的测试数据
        let testData = Data(count: 4 * 1024 * 1024)

        // 设置 HEAD 响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL)

        // 设置每个分片的响应
        for i in 0 ..< 4 {
            let start = i * 1024 * 1024
            let end = min((i + 1) * 1024 * 1024 - 1, testData.count - 1)
            let chunkData = testData.subdata(in: start ..< end + 1)

            let chunkResponse = MockURLProtocol.MockResponse(
                data: chunkData,
                statusCode: 206,
                headers: [
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes \(start)-\(end)/\(testData.count)",
                ]
            )
            MockURLProtocol.register(mockResponse: chunkResponse, for: testURL)
        }

        // When
        downloadManager.start()

        // 多次暂停和恢复
        for _ in 0 ..< 3 {
            Thread.sleep(forTimeInterval: 0.5)
            downloadManager.pause()
            XCTAssertEqual(mockDelegate.stateUpdates.last, .paused)

            Thread.sleep(forTimeInterval: 0.5)
            downloadManager.resume()
            XCTAssertEqual(mockDelegate.stateUpdates.last, .downloading)
        }

        // Then
        wait(for: [completionExpectation], timeout: 10.0)
        XCTAssertEqual(mockDelegate.stateUpdates.last, .completed)
        XCTAssertNotNil(mockDelegate.completionURL)

        // 验证文件大小
        if let url = mockDelegate.completionURL {
            let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
            XCTAssertEqual(fileSize, Int64(testData.count))
        }
    }

    func testCancelDuringPause() {
        // Given
        let errorExpectation = XCTestExpectation(description: "Should handle cancel during pause")
        mockDelegate.errorExpectation = errorExpectation

        // 创建一个 2MB 的测试数据
        let testData = Data(count: 2 * 1024 * 1024)

        // 设置 HEAD 响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL)

        // When
        downloadManager.start()
        Thread.sleep(forTimeInterval: 0.5)
        downloadManager.pause()
        downloadManager.cancel()

        // Then
        wait(for: [errorExpectation], timeout: 5.0)
        XCTAssertEqual(mockDelegate.stateUpdates.last, .cancelled)
    }

    func testRapidStateChanges() {
        // Given
        let errorExpectation = XCTestExpectation(description: "Should handle rapid state changes")
        mockDelegate.errorExpectation = errorExpectation

        // 创建一个 1MB 的测试数据
        let testData = Data(count: 1024 * 1024)

        // 设置 HEAD 响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL)

        // When
        downloadManager.start()

        // 快速切换状态
        for _ in 0 ..< 10 {
            downloadManager.pause()
            downloadManager.resume()
            downloadManager.cancel()
            downloadManager.start()
        }

        // Then
        wait(for: [errorExpectation], timeout: 5.0)
        XCTAssertNotNil(mockDelegate.lastError)
    }

    func testChunkSizeBoundary() {
        // Given
        let completionExpectation = XCTestExpectation(description: "Should handle chunk size boundary")
        mockDelegate.completionExpectation = completionExpectation

        // 创建一个刚好等于分片大小的数据
        let chunkSize = Int64(1024 * 1024) // 1MB
        let testData = Data(count: Int(chunkSize))

        // 设置 HEAD 响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL)

        // 设置 GET 响应
        let getResponse = MockURLProtocol.MockResponse(
            data: testData,
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: getResponse, for: testURL)

        // When
        downloadManager.start()

        // Then
        wait(for: [completionExpectation], timeout: 5.0)
        XCTAssertEqual(mockDelegate.stateUpdates.last, .completed)
        XCTAssertNotNil(mockDelegate.completionURL)

        // 验证文件大小
        if let url = mockDelegate.completionURL {
            let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
            XCTAssertEqual(fileSize, Int64(testData.count))
        }
    }

    func testEmptyFile() {
        // Given
        let completionExpectation = XCTestExpectation(description: "Should handle empty file")
        mockDelegate.completionExpectation = completionExpectation

        // 创建一个空文件
        let emptyData = Data()

        // 设置 HEAD 响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "0",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL)

        // 设置 GET 响应
        let getResponse = MockURLProtocol.MockResponse(
            data: emptyData,
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "0",
            ]
        )
        MockURLProtocol.register(mockResponse: getResponse, for: testURL)

        // When
        downloadManager.start()

        // Then
        wait(for: [completionExpectation], timeout: 5.0)
        XCTAssertEqual(mockDelegate.stateUpdates.last, .completed)
        XCTAssertNotNil(mockDelegate.completionURL)

        // 验证文件大小
        if let url = mockDelegate.completionURL {
            let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
            XCTAssertEqual(fileSize, 0)
        }
    }
}

// MARK: - Mock Classes

private class MockChunkDownloadManagerDelegate: ChunkDownloadManagerDelegate {
    var stateUpdates: [DownloadState] = []
    var progressUpdates: [Double] = []
    var lastError: Error?
    var completionURL: URL?

    var completionExpectation: XCTestExpectation?
    var progressExpectation: XCTestExpectation?
    var errorExpectation: XCTestExpectation?

    func chunkDownloadManager(_ manager: ChunkDownloadManager, didUpdateProgress progress: Double) {
        progressUpdates.append(progress)
        progressExpectation?.fulfill()
    }

    func chunkDownloadManager(_ manager: ChunkDownloadManager, didUpdateState state: DownloadState) {
        stateUpdates.append(state)
        if state == .completed {
            completionExpectation?.fulfill()
        }
    }

    func chunkDownloadManager(_ manager: ChunkDownloadManager, didCompleteWithURL url: URL) {
        completionURL = url
        completionExpectation?.fulfill()
    }

    func chunkDownloadManager(_ manager: ChunkDownloadManager, didFailWithError error: Error) {
        lastError = error
        errorExpectation?.fulfill()
    }
}

// private class MockDownloadTask: DownloadTaskProtocol {
//    let url: URL
//    let destinationURL: URL
//
//    init(url: URL, destinationURL: URL) {
//        self.url = url
//        self.destinationURL = destinationURL
//    }
//
//    func sha256() -> String {
//        let combinedString = "\(url.absoluteString)\n\(destinationURL.absoluteString)"
//        if let data = combinedString.data(using: .utf8) {
//            let digest = SHA256.hash(data: data)
//            return digest.compactMap { String(format: "%02x", $0) }.joined()
//        }
//        return ""
//    }
// }
