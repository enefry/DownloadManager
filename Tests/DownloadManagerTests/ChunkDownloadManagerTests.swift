import CryptoKit
@testable import DownloadManager
import LoggerProxy
import XCTest

final class ChunkDownloadManagerTests: XCTestCase {
    // MARK: - Test Properties

    private var downloadManager: ChunkDownloadManager!
    private var mockDelegate: MockChunkDownloadManagerDelegate!
    private var mockDownloadTask: DownloadTask!
    private var downloadTaskConfiguration: DownloadTaskConfiguration!
    private var mockConfiguration: ChunkConfiguration!

    private let testURL = URL(string: "https://example.com/test.file")!
    private let testData = "Test data".data(using: .utf8)!

    // MARK: - Test Setup

    override func setUp() {
        print("\(#function):\(#line)")
        super.setUp()

        // 注册 MockURLProtocol
        URLProtocol.registerClass(MockURLProtocol.self)
        downloadTaskConfiguration = DownloadTaskConfiguration(
            headers: [:],
            timeoutIntervalForRequest: 30,
            protocolClasses: [NSStringFromClass(MockURLProtocol.self)]
        )

        // Create mock download task
        mockDownloadTask = DownloadTask(
            url: testURL,
            destinationURL: createUniqueDestinationURL(),
            configuration: downloadTaskConfiguration
        )

        // Create mock configuration
        mockConfiguration = ChunkConfiguration(
            chunkSize: 1024 * 1024, // 1MB
            maxConcurrentChunks: 3
        )

        // Create mock delegate
        mockDelegate = MockChunkDownloadManagerDelegate()

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
        print("\(#function):\(#line)")

        // 清理文件
        cleanupFiles()

        // 重置Mock
        MockURLProtocol.reset()
        URLProtocol.unregisterClass(MockURLProtocol.self)

        downloadManager = nil
        mockDelegate = nil
        mockDownloadTask = nil
        mockConfiguration = nil

        super.tearDown()
    }

    // MARK: - Helper Methods

    private func createUniqueDestinationURL() -> URL {
        let uniqueFileName = "test_\(UUID().uuidString).file"
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(uniqueFileName)
    }

    private func cleanupFiles() {
        if let destinationURL = mockDownloadTask?.destinationURL {
            try? FileManager.default.removeItem(at: destinationURL)
            try? FileManager.default.removeItem(at: destinationURL.deletingLastPathComponent())
        }
    }

    private func setupDefaultMockResponse() {
        print("\(#function):\(#line)")
        MockURLProtocol.reset()

        // 设置 HEAD 请求的响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL, method: "HEAD")

        // 设置 GET 请求的响应
        let getResponse = MockURLProtocol.MockResponse(
            data: testData,
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: getResponse, for: testURL, method: "GET")
    }

    private func setupMockResponse(with data: Data) {
        MockURLProtocol.reset()

        // 设置 HEAD 响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(data.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL, method: "HEAD")

        // 设置完整文件 GET 响应
        let fullGetResponse = MockURLProtocol.MockResponse(
            data: data,
            statusCode: 200,
            headers: [
                "Content-Length": "\(data.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: fullGetResponse, for: testURL, method: "GET")

        // 设置分片下载的动态处理
        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url, url == self.testURL else { return nil }

            if let rangeHeader = request.allHTTPHeaderFields?["Range"] {
                return self.handleRangeRequest(rangeHeader: rangeHeader, data: data)
            }

            return nil
        }
    }

    private func handleRangeRequest(rangeHeader: String, data: Data) -> MockURLProtocol.MockResponse? {
        let cleanRange = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
        let parts = cleanRange.split(separator: "-")

        guard parts.count == 2,
              let start = Int(parts[0]),
              let end = Int(parts[1]),
              start < data.count,
              end < data.count else {
            return nil
        }

        let requestedLength = end - start + 1
//        let chunkData = data.subdata(in: start ..< (start + requestedLength))
        let ContentRange = "bytes \(start)-\(end)/\(data.count)"
        let uuid = "\(UUID().uuidString)"
        let headers = [
            "Accept-Ranges": "bytes",
            "Content-Range": ContentRange,
            "Content-Length": "\(requestedLength)",
            "UUID": uuid,
        ]
        print("==>\(headers) <<< \(rangeHeader)")
        return MockURLProtocol.MockResponse(
            data: data,
            statusCode: 206,
            headers: headers
        )
    }

    private func setupMockErrorResponse(statusCode: Int) {
        MockURLProtocol.reset()
        let errorResponse = MockURLProtocol.MockResponse(
            statusCode: statusCode,
            error: NSError(domain: "HTTPError", code: statusCode, userInfo: nil)
        )
        MockURLProtocol.register(mockResponse: errorResponse, for: testURL)
    }

    // MARK: - Test Cases

    func testInitialization() {
        print("\(#function):\(#line)")
        XCTAssertNotNil(downloadManager)
        XCTAssertEqual(mockDelegate.stateUpdates.count, 0)

        let expectation = XCTestExpectation(description: "Get initial state")
        Task {
            let currentState = await self.downloadManager.state
            XCTAssertEqual(currentState, .initialed)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testStartDownload() async {
        print("\(#function):\(#line)")

        let preparingExpectation = XCTestExpectation(description: "Should enter preparing state")
        let downloadingExpectation = XCTestExpectation(description: "Should enter downloading state")
        var stateSequence: [DownloadState] = []

        mockDelegate.onStateUpdate = { state in
            print("State update: \(state)")
            stateSequence.append(state)

            switch state {
            case .preparing:
                preparingExpectation.fulfill()
            case .downloading:
                downloadingExpectation.fulfill()
            default:
                break
            }
        }

        await downloadManager.start()

        await fulfillment(of: [preparingExpectation], timeout: 5.0)
        await fulfillment(of: [downloadingExpectation], timeout: 10.0)

        XCTAssertTrue(stateSequence.contains(.preparing), "Should have preparing state")
        XCTAssertTrue(stateSequence.contains(.downloading), "Should have downloading state")
    }

    func testPauseAndResume() async {
        print("\(#function):\(#line)")

        let largeTestData = Data(count: 10 * 1024 * 1024) // 10MB
        setupMockResponse(with: largeTestData)

        var stateSequence: [DownloadState] = []
        var downloadingCount = 0
        let testExpectation = XCTestExpectation(description: "Complete pause/resume cycle")

        mockDelegate.onStateUpdate = { state in
            print("State: \(state)")
            stateSequence.append(state)

            switch state {
            case .downloading:
                downloadingCount += 1
                if downloadingCount == 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        Task {
                            await self.downloadManager.pause()
                        }
                    }
                } else if downloadingCount == 2 {
                    testExpectation.fulfill()
                }
            case .paused:
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    Task {
                        await self.downloadManager.resume()
                    }
                }
            default:
                break
            }
        }

        await downloadManager.start()

        await fulfillment(of: [testExpectation], timeout: 15.0)

        XCTAssertGreaterThanOrEqual(downloadingCount, 1, "Should enter downloading state at least once")
        XCTAssertTrue(stateSequence.contains(.downloading), "Should have downloading state")
        XCTAssertTrue(stateSequence.contains(.paused), "Should have paused state")
    }

    func testCancel() async {
        print("\(#function):\(#line)")

        let largeTestData = Data(count: 3 * 1024 * 1024) // 3MB
        setupMockResponse(with: largeTestData)

        let cancelExpectation = XCTestExpectation(description: "Should be cancelled")
        var hasStartedDownloading = false

        mockDelegate.onStateUpdate = { state in
            print("State changed to: \(state)")

            switch state {
            case .downloading:
                if !hasStartedDownloading {
                    hasStartedDownloading = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.downloadManager.cancel()
                    }
                }
            case .cancelled:
                if hasStartedDownloading {
                    cancelExpectation.fulfill()
                }
            default:
                break
            }
        }

        await downloadManager.start()

        await fulfillment(of: [cancelExpectation], timeout: 10.0)

        let stateExpectation = XCTestExpectation(description: "Verify final state")
        Task {
            let finalState = await self.downloadManager.state
            XCTAssertEqual(finalState, .cancelled)
            stateExpectation.fulfill()
        }
        await fulfillment(of: [stateExpectation], timeout: 1.0)

        XCTAssertTrue(mockDelegate.stateUpdates.contains(.cancelled), "Should have cancelled state")
    }

    func testProgressUpdates() async {
        print("\(#function):\(#line)")

        let progressExpectation = XCTestExpectation(description: "Progress should be updated")
        var progressCount = 0

        mockDelegate.onProgressDoubleUpdate = { progress in
            progressCount += 1
            print("Progress: \(progress)")
            if progressCount >= 1 {
                progressExpectation.fulfill()
            }
        }

        await downloadManager.start()

        await fulfillment(of: [progressExpectation], timeout: 10.0)
        XCTAssertGreaterThanOrEqual(mockDelegate.progressUpdates.count, 1)

        for progress in mockDelegate.progressUpdates {
            let progressRatio = progress.1 > 0 ? Double(progress.0) / Double(progress.1) : 0.0
            XCTAssertTrue(progressRatio >= 0.0 && progressRatio <= 1.0,
                          "Progress ratio should be between 0.0 and 1.0, got \(progressRatio)")
        }
    }

    func testErrorHandling() async {
        print("\(#function):\(#line)")

        let errorExpectation = XCTestExpectation(description: "Error should be handled")

        mockDelegate.onError = { error in
            print("Error received: \(error)")
            errorExpectation.fulfill()
        }

        MockURLProtocol.reset()
        let errorResponse = MockURLProtocol.MockResponse(
            statusCode: 404,
            error: NSError(domain: "TestError", code: 404, userInfo: nil)
        )
        MockURLProtocol.register(mockResponse: errorResponse, for: testURL)

        await downloadManager.start()

        await fulfillment(of: [errorExpectation], timeout: 10.0)
        XCTAssertNotNil(mockDelegate.lastError)
    }

    func testChunkDownload() async {
        print("\(#function):\(#line)")

        let completionExpectation = XCTestExpectation(description: "Download should complete")

        mockDelegate.onCompletion = { url in
            print("Download completed at: \(url)")
            completionExpectation.fulfill()
        }

        let largeData = Data(count: 5 * 1024 * 1024) // 5MB
        setupMockResponse(with: largeData)

        await downloadManager.start()

        await fulfillment(of: [completionExpectation], timeout: 30.0)
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)

        XCTAssertTrue(mockDelegate.stateUpdates.contains(.completed), "Should have completed state")
        XCTAssertNotNil(mockDelegate.completionURL)

        if let completionURL = mockDelegate.completionURL {
            let exists = FileManager.default.fileExists(atPath: completionURL.path)
            XCTAssertTrue(exists, "Downloaded file should exist \(completionURL) => \(exists)")
        }
    }

    // 在测试文件中，修改 testServerNotSupportingRanges 方法
    func testServerNotSupportingRanges() async {
        print("\(#function):\(#line)")
        let testData = Data(count: 1 * 1024 * 1024)
        let downloadingExpectation = XCTestExpectation(description: "Should enter downloading state")
        let completionExpectation = XCTestExpectation(description: "Should complete normally")
        var stateSequence: [DownloadState] = []

        mockDelegate.onStateUpdate = { state in
            print("State update: \(state)")
            stateSequence.append(state)

            if state == .downloading {
                downloadingExpectation.fulfill()
            }
        }

        mockDelegate.onCompletion = { _ in
            completionExpectation.fulfill()
        }

        MockURLProtocol.reset()

        // 设置不支持分片下载的HEAD响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Content-Length": "\(testData.count)",
                // 故意不设置 Accept-Ranges
            ],
            streamChunks: false
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL, method: "HEAD")

        // 设置GET Range请求返回非206状态码
        MockURLProtocol.setRequestHandler { request in
            if let rangeHeader = request.allHTTPHeaderFields?["Range"] {
                // Range请求返回200而不是206，表示不支持范围请求
                return MockURLProtocol.MockResponse(
                    data: testData,
                    statusCode: 200,
                    headers: [
                        "Content-Length": "\(testData.count)",
                    ],
                    streamChunks: false
                )
            }

            // 正常的GET请求
            if request.httpMethod == "GET" && request.allHTTPHeaderFields?["Range"] == nil {
                return MockURLProtocol.MockResponse(
                    data: testData,
                    statusCode: 200,
                    headers: [
                        "Content-Length": "\(testData.count)",
                    ],
                    streamChunks: false
                )
            }

            return nil
        }

        await downloadManager.start()

        await fulfillment(of: [downloadingExpectation], timeout: 10.0)
        await fulfillment(of: [completionExpectation], timeout: 10.0)
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        XCTAssertTrue(stateSequence.contains(.preparing), "Should have preparing state")
        XCTAssertTrue(stateSequence.contains(.downloading), "Should have downloading state")
        XCTAssertTrue(mockDelegate.stateUpdates.contains(.completed), "Should complete successfully")
    }

    // 在测试文件中，修改 testServerNotSupportingRanges 方法
    func testServerNotSupportingRangesPauseAndCancel() async {
        print("\(#function):\(#line)")
        let testData = Data(count: 1 * 1024 * 1024)
        let downloadingExpectation = XCTestExpectation(description: "Should enter downloading state")
        let completionExpectation = XCTestExpectation(description: "Should complete normally")
        var stateSequence: [DownloadState] = []

        mockDelegate.onStateUpdate = { state in
            print("State update: \(state)")
            stateSequence.append(state)

            if state == .downloading {
                downloadingExpectation.fulfill()
            }
        }

        mockDelegate.onCompletion = { _ in
            completionExpectation.fulfill()
        }

        MockURLProtocol.reset()

        // 设置不支持分片下载的HEAD响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Content-Length": "\(testData.count)",
                // 故意不设置 Accept-Ranges
            ],
            streamChunks: false
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL, method: "HEAD")

        // 设置GET Range请求返回非206状态码
        MockURLProtocol.setRequestHandler { request in
            if let rangeHeader = request.allHTTPHeaderFields?["Range"] {
                // Range请求返回200而不是206，表示不支持范围请求
                return MockURLProtocol.MockResponse(
                    data: testData,
                    statusCode: 200,
                    headers: [
                        "Content-Length": "\(testData.count)",
                    ],
                    streamChunks: false
                )
            }

            // 正常的GET请求
            if request.httpMethod == "GET" && request.allHTTPHeaderFields?["Range"] == nil {
                return MockURLProtocol.MockResponse(
                    data: testData,
                    statusCode: 200,
                    headers: [
                        "Content-Length": "\(testData.count)",
                    ],
                    streamChunks: false
                )
            }

            return nil
        }

        await downloadManager.start()

        await fulfillment(of: [downloadingExpectation], timeout: 10.0)
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        await downloadManager.pause()
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        await downloadManager.cancel()
        XCTAssertTrue(stateSequence.contains(.preparing), "Should have preparing state")
        XCTAssertTrue(stateSequence.contains(.downloading), "Should have downloading state")
        XCTAssertTrue(mockDelegate.stateUpdates.contains(.cancelled), "Should complete successfully")
    }

    func testServerNotSupportingRangesFail() async {
        print("\(#function):\(#line)")
        let testData = Data(count: 1 * 1024 * 1024)
        let downloadingExpectation = XCTestExpectation(description: "Should enter downloading state")
        let completionExpectation = XCTestExpectation(description: "Should complete normally")
        let failExpectation = XCTestExpectation(description: "Should failExpectation normally")
        var stateSequence: [DownloadState] = []

        mockDelegate.onStateUpdate = { state in
            print("State update: \(state)")
            stateSequence.append(state)
            if state == .downloading{
                downloadingExpectation.fulfill()
            }
            if state.isFailed {
                failExpectation.fulfill()
            }
        }

        mockDelegate.onCompletion = { _ in
            completionExpectation.fulfill()
        }

        MockURLProtocol.reset()

        // 设置不支持分片下载的HEAD响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Content-Length": "\(testData.count * 3)",
                // 故意不设置 Accept-Ranges
            ],
            streamChunks: false
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL, method: "HEAD")

        // 设置GET Range请求返回非206状态码
        MockURLProtocol.setRequestHandler { request in
            if let rangeHeader = request.allHTTPHeaderFields?["Range"] {
                // Range请求返回200而不是206，表示不支持范围请求
                return MockURLProtocol.MockResponse(
                    data: testData,
                    statusCode: 200,
                    headers: [
                        "Content-Length": "\(testData.count * 3)",
                    ],
                    streamChunks: false
                )
            }

            // 正常的GET请求
            if request.httpMethod == "GET" && request.allHTTPHeaderFields?["Range"] == nil {
                return MockURLProtocol.MockResponse(
                    data: testData,
                    statusCode: 200,
                    headers: [
                        "Content-Length": "\(testData.count * 3)",
                    ],
                    streamChunks: false
                )
            }

            return nil
        }

        await downloadManager.start()

        await fulfillment(of: [downloadingExpectation], timeout: 10.0)

        XCTAssertTrue(stateSequence.contains(.preparing), "Should have preparing state")
        XCTAssertTrue(stateSequence.contains(.downloading), "Should have downloading state")

        await fulfillment(of: [failExpectation], timeout: 10.0)
        let isfail = stateSequence.last?.isFailed ?? false
        XCTAssertTrue(isfail, "最终结果应该是失败！")
    }

    func testServerResumeNotSupportingRanges() async {
        print("\(#function):\(#line)")
        let testData = Data(count: 5 * 1024 * 1024)

        let downloadingExpectation = XCTestExpectation(description: "Should enter downloading state")
        let completionExpectation = XCTestExpectation(description: "Should complete normally")
        var stateSequence: [DownloadState] = []

        mockDelegate.onStateUpdate = { state in
            print("State update: \(state)")
            stateSequence.append(state)

            if state == .downloading {
                downloadingExpectation.fulfill()
            }
        }

        mockDelegate.onCompletion = { _ in
            completionExpectation.fulfill()
        }

        MockURLProtocol.reset()

        // 设置不支持分片下载的HEAD响应
        let headResponse = MockURLProtocol.MockResponse(
            data: testData,
            statusCode: 200,
            headers: [
                "Content-Length": "\(testData.count)",
            ],
            streamChunks: false,
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL, method: "HEAD")

        // 设置GET Range请求返回非206状态码
        MockURLProtocol.setRequestHandler { request in
            if let rangeHeader = request.allHTTPHeaderFields?["Range"] {
                // Range请求返回200而不是206，表示不支持范围请求
                return MockURLProtocol.MockResponse(
                    data: testData,
                    statusCode: 200,
                    headers: [
                        "Content-Length": "\(testData.count)",
                    ],
                    streamChunks: false,
                )
            }

            // 正常的GET请求
            if request.httpMethod == "GET" && request.allHTTPHeaderFields?["Range"] == nil {
                return MockURLProtocol.MockResponse(
                    data: testData,
                    statusCode: 200,
                    headers: [
                        "Content-Length": "\(testData.count)",
                    ],
                    streamChunks: false,
                )
            }

            return nil
        }

        await downloadManager.start()
        await fulfillment(of: [downloadingExpectation], timeout: 10.0)
        // 开始下载后就可以暂停了
        await downloadManager.pause()
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 1000)
        // 暂停一会在继续
        await downloadManager.resume()
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 1000)
        await fulfillment(of: [completionExpectation], timeout: 30.0)
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        XCTAssertTrue(stateSequence.contains(.preparing), "Should have preparing state")
        XCTAssertTrue(stateSequence.contains(.paused), "Should have preparing state")
        XCTAssertTrue(stateSequence.contains(.downloading), "Should have downloading state")
        XCTAssertTrue(mockDelegate.stateUpdates.contains(.completed), "Should complete successfully")
    }

    func testLargeFileChunkDownload() async {
        print("\(#function):\(#line)")

        let completionExpectation = XCTestExpectation(description: "Large file download should complete")

        mockDelegate.onCompletion = { _ in
            completionExpectation.fulfill()
        }

        let largeData = Data(count: 8 * 1024 * 1024) // 8MB
        setupMockResponse(with: largeData)

        await downloadManager.start()

        await fulfillment(of: [completionExpectation], timeout: 45.0)
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        XCTAssertTrue(mockDelegate.stateUpdates.contains(.completed), "Should have completed state")
        XCTAssertNotNil(mockDelegate.completionURL)

        if let url = mockDelegate.completionURL {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attributes[.size] as? Int64
                XCTAssertEqual(fileSize, Int64(largeData.count))
            } catch {
                XCTFail("Failed to get file attributes: \(error)")
            }
        }
    }

    func testNetworkTimeout() async {
        print("\(#function):\(#line)")

        let errorExpectation = XCTestExpectation(description: "Should handle network timeout")

        mockDelegate.onError = { error in
            print("Timeout error: \(error)")
            errorExpectation.fulfill()
        }

        MockURLProtocol.reset()
        let timeoutResponse = MockURLProtocol.MockResponse(
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil),
            delay: 1.0
        )
        MockURLProtocol.register(mockResponse: timeoutResponse, for: testURL)

        await downloadManager.start()

        await fulfillment(of: [errorExpectation], timeout: 10.0)
        XCTAssertNotNil(mockDelegate.lastError)
    }

    func testEmptyFile() async {
        print("\(#function):\(#line)")

        let completionExpectation = XCTestExpectation(description: "Should handle empty file")

        mockDelegate.onCompletion = { _ in
            completionExpectation.fulfill()
        }

        let emptyData = Data()
        setupMockResponse(with: emptyData)

        await downloadManager.start()

        await fulfillment(of: [completionExpectation], timeout: 5.0)
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        XCTAssertTrue(mockDelegate.stateUpdates.contains(.completed), "Should complete empty file download")
        XCTAssertNotNil(mockDelegate.completionURL)

        if let url = mockDelegate.completionURL {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attributes[.size] as? Int64
                XCTAssertEqual(fileSize, 0)
            } catch {
                XCTFail("Failed to get file attributes: \(error)")
            }
        }
    }

    func testInvalidResponseHeaders() async {
        print("\(#function):\(#line)")

        let errorOrDownloadExpectation = XCTestExpectation(description: "Should handle invalid response headers")

        var errorReceived = false
        var downloadCompleted = false

        mockDelegate.onError = { _ in
            errorReceived = true
            errorOrDownloadExpectation.fulfill()
        }

        mockDelegate.onStateUpdate = { state in
            if state == .downloading {
                downloadCompleted = true
                errorOrDownloadExpectation.fulfill()
            }
        }

        MockURLProtocol.reset()
        let invalidResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [:]
        )
        MockURLProtocol.register(mockResponse: invalidResponse, for: testURL)

        await downloadManager.start()

        await fulfillment(of: [errorOrDownloadExpectation], timeout: 10.0)

        XCTAssertTrue(errorReceived || downloadCompleted, "Should either error or handle gracefully")
    }

    func testRapidStateChanges() async {
        print("\(#function):\(#line)")

        let stateChangeExpectation = XCTestExpectation(description: "Should handle rapid state changes gracefully")
        let largeData = Data(count: 5 * 1024 * 1024) // 5MB
        setupMockResponse(with: largeData)

        var stateChanges = 0
        mockDelegate.onStateUpdate = { state in
            stateChanges += 1
            print("State change \(stateChanges): \(state)")

            if stateChanges >= 4 {
                stateChangeExpectation.fulfill()
            }
        }

        await downloadManager.start()

        try? await Task.sleep(nanoseconds: UInt64(kSecondScale))
        await downloadManager.pause()
        try? await Task.sleep(nanoseconds: UInt64(kSecondScale))
        await downloadManager.resume()
        try? await Task.sleep(nanoseconds: UInt64(kSecondScale))
        await downloadManager.cancel()
        await fulfillment(of: [stateChangeExpectation], timeout: 10.0)
        XCTAssertGreaterThanOrEqual(mockDelegate.stateUpdates.count, 3, "Should have received multiple state updates")
    }

    func testResumeFromPartialDownload() async {
        print("\(#function):\(#line)")

        let totalFileSize: Int64 = 8 * 1024 * 1024 // 8MB
        let largeTestData = Data(count: Int(totalFileSize))
        setupMockResponse(with: largeTestData)

        let firstDownloadExpectation = XCTestExpectation(description: "第一次下载应开始并中断")
        let resumeExpectation = XCTestExpectation(description: "恢复下载应成功完成")

        var isFirstDownload = true
        mockDelegate.onProgressDoubleUpdate = { progress in
            print(">>progress:\(progress)")
            if isFirstDownload {
                if progress > 0.3 {
                    print("在进度 \(progress) 处模拟中断")
                    Task {
                        await self.downloadManager.cancel()
                        firstDownloadExpectation.fulfill()
                    }
                }
            }
        }

        await downloadManager.start()
        await fulfillment(of: [firstDownloadExpectation], timeout: 10.0)

        downloadManager = nil
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        // 重新设置进行恢复测试
        isFirstDownload = false
        mockDelegate = MockChunkDownloadManagerDelegate()
        downloadManager = ChunkDownloadManager(
            downloadTask: mockDownloadTask,
            configuration: mockConfiguration,
            delegate: mockDelegate
        )

        setupMockResponse(with: largeTestData)

        mockDelegate.onCompletion = { url in
            print("onCompletion=>\(url)")
            resumeExpectation.fulfill()
        }

        await downloadManager.start()

        await fulfillment(of: [resumeExpectation], timeout: 20.0)
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        XCTAssertTrue(mockDelegate.stateUpdates.contains(.completed), "恢复的下载应完成")
        XCTAssertNotNil(mockDelegate.completionURL)

        if let url = mockDelegate.completionURL {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attributes[.size] as? Int64
                XCTAssertEqual(fileSize, totalFileSize, "恢复的文件大小应与原始文件匹配")
            } catch {
                XCTFail("恢复后无法获取文件属性: \(error)")
            }
        }
    }

    // MARK: - Configuration Tests

    func testInitializationWithDifferentConfigurations() async {
        print("\(#function):\(#line)")

        // Test with minimum chunk size
        let minConfig = ChunkConfiguration(
            chunkSize: 1024, // 1KB
            maxConcurrentChunks: 1
        )

        let minManager = ChunkDownloadManager(
            downloadTask: mockDownloadTask,
            configuration: minConfig,
            delegate: mockDelegate
        )

        XCTAssertNotNil(minManager)

        // Test with maximum chunk size
        let maxConfig = ChunkConfiguration(
            chunkSize: 100 * 1024 * 1024, // 100MB
            maxConcurrentChunks: 10
        )

        let maxManager = ChunkDownloadManager(
            downloadTask: mockDownloadTask,
            configuration: maxConfig,
            delegate: mockDelegate
        )

        XCTAssertNotNil(maxManager)

        let stateExpectation = XCTestExpectation(description: "Verify initial states")
        Task {
            let minState = await minManager.state
            let maxState = await maxManager.state
            XCTAssertEqual(minState, .initialed)
            XCTAssertEqual(maxState, .initialed)
            stateExpectation.fulfill()
        }
        await fulfillment(of: [stateExpectation], timeout: 1.0)
    }

    // MARK: - State Management Tests

    func testInvalidStateTransitions() async {
        print("\(#function):\(#line)")
        var states: [DownloadState] = []
        var needDownloading = false
        var downloadingExcept = XCTestExpectation(description: "开始下载事件")
        mockDelegate.onStateUpdate = {
            print("状态切换:\($0)")
            states.append($0)
            if needDownloading {
                downloadingExcept.fulfill()
                needDownloading = false
            }
        }
        setupMockResponse(with: Data(count: 1 * 1024 * 1024))
        await downloadManager.start()
        var state = await downloadManager.state
        XCTAssertEqual(state, .preparing, "应该是开始下载了")

        var stateCount = states.count
        await downloadManager.resume()
        XCTAssertEqual(stateCount, states.count, "这个时候还没那么快切换到下载，无法恢复下载")

        needDownloading = true
        await fulfillment(of: [downloadingExcept], timeout: 1)
        // 应该已经开始下载
        state = await downloadManager.state
        XCTAssertEqual(state, .downloading, "应该已经在下载")
        stateCount = states.count
        await downloadManager.resume()
        XCTAssertEqual(stateCount, states.count, "这个时候已经下载，无法恢复下载")

        state = await downloadManager.state
        XCTAssertEqual(state, .downloading, "已经在下载，不需要恢复")

        await downloadManager.pause()

        state = await downloadManager.state
        XCTAssertEqual(state, .paused, "应该切换到暂停状态")

        await downloadManager.resume()
        state = await downloadManager.state
        XCTAssertEqual(state, .downloading, "这个时候应该恢复下载")

        await downloadManager.cancel()
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        state = await downloadManager.state
        XCTAssertEqual(state, .cancelled, "Should be able to cancel from paused state")
        await downloadManager.cleanup()
    }

    func testMultipleStartCalls() async {
        print("\(#function):\(#line)")

        let largeData = Data(count: 2 * 1024 * 1024) // 2MB
        setupMockResponse(with: largeData)

        let expectation = XCTestExpectation(description: "Should handle multiple start calls gracefully")
        var preparingCount = 0

        mockDelegate.onStateUpdate = { state in
            if state == .preparing {
                preparingCount += 1
            }
            if preparingCount >= 1 && state == .downloading {
                expectation.fulfill()
            }
        }

        // Call start multiple times rapidly
        await downloadManager.start()
        await downloadManager.start()
        await downloadManager.start()

        await fulfillment(of: [expectation], timeout: 10.0)

        XCTAssertEqual(preparingCount, 1, "Should only prepare once despite multiple start calls")
    }

    // MARK: - Error Handling Tests

    func testHttpErrorResponses() async {
        print("\(#function):\(#line)")

        let testCases = [
            (statusCode: 404, description: "Not Found"),
            (statusCode: 403, description: "Forbidden"),
            (statusCode: 500, description: "Internal Server Error"),
            (statusCode: 503, description: "Service Unavailable"),
        ]

        for (statusCode, description) in testCases {
            // 为每个测试case创建新的实例
            let uniqueURL = URL(string: "https://example.com/test_\(statusCode).file")!
            let uniqueTask = DownloadTask(
                url: uniqueURL,
                destinationURL: createUniqueDestinationURL(),
                configuration: downloadTaskConfiguration
            )
            let uniqueDelegate = MockChunkDownloadManagerDelegate()
            let uniqueManager = ChunkDownloadManager(
                downloadTask: uniqueTask,
                configuration: mockConfiguration,
                delegate: uniqueDelegate
            )

            let errorExpectation = XCTestExpectation(description: "Should handle \(statusCode) error")

            uniqueDelegate.onError = { _ in
                errorExpectation.fulfill()
            }

            setupMockErrorResponse(statusCode: statusCode)
            MockURLProtocol.register(
                mockResponse: MockURLProtocol.MockResponse(
                    statusCode: statusCode,
                    error: NSError(domain: "HTTPError", code: statusCode, userInfo: nil)
                ),
                for: uniqueURL
            )

            await uniqueManager.start()

            await fulfillment(of: [errorExpectation], timeout: 5.0)
            XCTAssertNotNil(uniqueDelegate.lastError, "Should receive error for \(description)")
        }
    }

    func testNetworkConnectionErrors() async {
        print("\(#function):\(#line)")

        let networkErrors = [
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: nil),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorDNSLookupFailed, userInfo: nil),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: nil),
        ]

        for (index, error) in networkErrors.enumerated() {
            // 为每个测试case创建新的实例
            let uniqueURL = URL(string: "https://example.com/test_error_\(index).file")!
            let uniqueTask = DownloadTask(
                url: uniqueURL,
                destinationURL: createUniqueDestinationURL(),
                configuration: downloadTaskConfiguration
            )
            let uniqueDelegate = MockChunkDownloadManagerDelegate()
            let uniqueManager = ChunkDownloadManager(
                downloadTask: uniqueTask,
                configuration: mockConfiguration,
                delegate: uniqueDelegate
            )

            let errorExpectation = XCTestExpectation(description: "Should handle network error \(index)")

            uniqueDelegate.onError = { _ in
                errorExpectation.fulfill()
            }

            let errorResponse = MockURLProtocol.MockResponse(error: error)
            MockURLProtocol.register(mockResponse: errorResponse, for: uniqueURL)

            await uniqueManager.start()

            await fulfillment(of: [errorExpectation], timeout: 5.0)
            XCTAssertNotNil(uniqueDelegate.lastError)
        }
    }

    // MARK: - Chunk Size Tests

    func testSmallChunkSize() async {
        print("\(#function):\(#line)")

        let smallChunkConfig = ChunkConfiguration(
            chunkSize: 100,
            maxConcurrentChunks: 8,
        )
        mockDownloadTask.taskConfigure.timeoutIntervalForRequest = 20
        let smallChunkManager = ChunkDownloadManager(
            downloadTask: mockDownloadTask,
            configuration: smallChunkConfig,
            delegate: mockDelegate
        )

        let completionExpectation = XCTestExpectation(description: "Small chunk download should complete")
        let progressExpectation = XCTestExpectation(description: "Should receive multiple progress updates")
        var progressUpdateCount = 0

        mockDelegate.onCompletion = { _ in
            completionExpectation.fulfill()
        }

        mockDelegate.onProgressDoubleUpdate = { _ in
            progressUpdateCount += 1
            progressExpectation.fulfill()
        }

        let testData = Data(count: 1 * 1024) // 1KB data with 100-byte chunks
        setupMockResponse(with: testData)

        await smallChunkManager.start()

        await fulfillment(of: [completionExpectation, progressExpectation], timeout: 20)

        XCTAssertGreaterThanOrEqual(progressUpdateCount, 1, "Should receive progress updates with small chunks")
    }

    func testLargeChunkSize() async {
        print("\(#function):\(#line)")

        let largeChunkConfig = ChunkConfiguration(
            chunkSize: 50 * 1024 * 1024, // 50MB chunks
            maxConcurrentChunks: 1
        )

        let largeChunkManager = ChunkDownloadManager(
            downloadTask: mockDownloadTask,
            configuration: largeChunkConfig,
            delegate: mockDelegate
        )

        let completionExpectation = XCTestExpectation(description: "Large chunk download should complete")

        mockDelegate.onCompletion = { _ in
            completionExpectation.fulfill()
        }

        let testData = Data(count: 5 * 1024 * 1024) // 5MB data
        setupMockResponse(with: testData)

        await largeChunkManager.start()

        await fulfillment(of: [completionExpectation], timeout: 20.0)
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        XCTAssertTrue(mockDelegate.stateUpdates.contains(.completed))
    }

    // MARK: - Concurrent Download Tests

    func testMaxConcurrentChunks() async {
        print("\(#function):\(#line)")

        let concurrencyLevels = [1, 2, 5, 10]

        for maxConcurrent in concurrencyLevels {
            let config = ChunkConfiguration(
                chunkSize: 512 * 1024, // 512KB
                maxConcurrentChunks: maxConcurrent
            )

            let uniqueTask = DownloadTask(
                url: URL(string: "https://example.com/test_concurrent_\(maxConcurrent).file")!,
                destinationURL: createUniqueDestinationURL(),
                configuration: downloadTaskConfiguration
            )
            let uniqueDelegate = MockChunkDownloadManagerDelegate()
            let manager = ChunkDownloadManager(
                downloadTask: uniqueTask,
                configuration: config,
                delegate: uniqueDelegate
            )

            let completionExpectation = XCTestExpectation(description: "Concurrent download should complete with \(maxConcurrent) chunks")

            uniqueDelegate.onCompletion = { _ in
                completionExpectation.fulfill()
            }

            let testData = Data(count: 3 * 1024 * 1024) // 3MB
            MockURLProtocol.register(
                mockResponse: MockURLProtocol.MockResponse(
                    statusCode: 200,
                    headers: ["Accept-Ranges": "bytes", "Content-Length": "\(testData.count)"]
                ),
                for: uniqueTask.url,
                method: "HEAD"
            )
            MockURLProtocol.register(
                mockResponse: MockURLProtocol.MockResponse(data: testData, statusCode: 200),
                for: uniqueTask.url,
                method: "GET"
            )

            await manager.start()

            await fulfillment(of: [completionExpectation], timeout: 15.0)
            try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
            XCTAssertTrue(uniqueDelegate.stateUpdates.contains(.completed), "Should complete with \(maxConcurrent) max concurrent chunks")
        }
    }

    // MARK: - File System Tests

    func testDestinationDirectoryCreation() async {
        print("\(#function):\(#line)")

        let nestedPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test")
            .appendingPathComponent("nested")
            .appendingPathComponent("directory")
            .appendingPathComponent("file.txt")

        let nestedDownloadTask = DownloadTask(
            url: testURL,
            destinationURL: nestedPath,
            configuration: downloadTaskConfiguration
        )

        let nestedManager = ChunkDownloadManager(
            downloadTask: nestedDownloadTask,
            configuration: mockConfiguration,
            delegate: mockDelegate
        )

        let completionExpectation = XCTestExpectation(description: "Should create nested directories")

        mockDelegate.onCompletion = { _ in
            completionExpectation.fulfill()
        }

        await nestedManager.start()

        await fulfillment(of: [completionExpectation], timeout: 10.0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedPath.path), "Nested file should exist")

        // Clean up
        try? FileManager.default.removeItem(at: nestedPath.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    }

    func testExistingFileOverwrite() async {
        print("\(#function):\(#line)")

        let existingContent = "Existing content".data(using: .utf8)!
        let destinationURL = mockDownloadTask.destinationURL

        do {
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try existingContent.write(to: destinationURL)

            XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path), "Existing file should exist")

            let completionExpectation = XCTestExpectation(description: "Should overwrite existing file")

            mockDelegate.onCompletion = { _ in
                completionExpectation.fulfill()
            }

            let newContent = "New content from download".data(using: .utf8)!
            setupMockResponse(with: newContent)

            await downloadManager.start()

            await fulfillment(of: [completionExpectation], timeout: 10.0)

            let finalContent = try Data(contentsOf: destinationURL)
            XCTAssertEqual(finalContent, newContent, "File should be overwritten with new content")

        } catch {
            XCTFail("Failed to set up existing file test: \(error)")
        }
    }

    // MARK: - Progress Tracking Tests

    func testProgressAccuracy() async {
        print("\(#function):\(#line)")

        let progressExpectation = XCTestExpectation(description: "Progress should be accurate")
        let completionExpectation = XCTestExpectation(description: "Download should complete")

        var progressValues: [Double] = []
        let fileSize = 2 * 1024 * 1024 // 2MB

        mockDelegate.onProgressDoubleUpdate = { progress in
            progressValues.append(progress)
        }

        mockDelegate.onCompletion = { _ in
            progressExpectation.fulfill()
            completionExpectation.fulfill()
        }

        let testData = Data(count: fileSize)
        setupMockResponse(with: testData)

        await downloadManager.start()

        await fulfillment(of: [progressExpectation, completionExpectation], timeout: 15.0)

        XCTAssertFalse(progressValues.isEmpty, "Should receive progress updates")
        XCTAssertTrue(progressValues.allSatisfy { $0 >= 0.0 && $0 <= 1.0 }, "All progress values should be between 0 and 1")

        let sortedProgress = progressValues.sorted()
        let originalProgress = progressValues
        let increasingCount = zip(sortedProgress, originalProgress).reduce(0) { count, pair in
            count + (pair.0 == pair.1 ? 1 : 0)
        }

        XCTAssertGreaterThan(Double(increasingCount) / Double(progressValues.count), 0.3, "Progress should generally increase")
    }

    func testProgressUpdateFrequency() async {
        print("\(#function):\(#line)")

        let expectation = XCTestExpectation(description: "Should limit progress update frequency")
        var progressUpdateTimes: [Date] = []

        mockDelegate.onProgressDoubleUpdate = { _ in
            progressUpdateTimes.append(Date())
        }

        mockDelegate.onCompletion = { _ in
            expectation.fulfill()
        }

        let testData = Data(count: 5 * 1024 * 1024) // 5MB
        setupMockResponse(with: testData)

        await downloadManager.start()

        await fulfillment(of: [expectation], timeout: 20.0)

        if progressUpdateTimes.count > 1 {
            let intervals = zip(progressUpdateTimes, progressUpdateTimes.dropFirst()).map { $1.timeIntervalSince($0) }
            let averageInterval = intervals.reduce(0, +) / Double(intervals.count)

            XCTAssertGreaterThanOrEqual(averageInterval, 0.05, "Progress updates should be throttled")
        }
    }

    // MARK: - Header and Configuration Tests

    func testCustomHeaders() async {
        print("\(#function):\(#line)")

        let customHeaders = [
            "Authorization": "Bearer test-token",
            "User-Agent": "TestApp/1.0",
            "X-Custom-Header": "custom-value",
        ]

        let configWithHeaders = ChunkConfiguration(
            chunkSize: mockConfiguration.chunkSize,
            maxConcurrentChunks: mockConfiguration.maxConcurrentChunks
        )
        mockDownloadTask.taskConfigure.headers = customHeaders

        let managerWithHeaders = ChunkDownloadManager(
            downloadTask: mockDownloadTask,
            configuration: configWithHeaders,
            delegate: mockDelegate
        )

        let completionExpectation = XCTestExpectation(description: "Download with custom headers should complete")

        mockDelegate.onCompletion = { _ in
            completionExpectation.fulfill()
        }

        await managerWithHeaders.start()

        await fulfillment(of: [completionExpectation], timeout: 10.0)
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        XCTAssertTrue(mockDelegate.stateUpdates.contains(.completed))
    }

    func testTimeoutConfiguration() async {
        print("\(#function):\(#line)")

        let taskConfigure = DownloadTaskConfiguration(
            headers: [:],
            timeoutIntervalForRequest: 1,
            timeoutIntervalForResource: 1,
            protocolClasses: [NSStringFromClass(MockURLProtocol.self)]
        )
        let shortTimeoutConfig = ChunkConfiguration(
            chunkSize: mockConfiguration.chunkSize,
            maxConcurrentChunks: mockConfiguration.maxConcurrentChunks
        )

        let timeoutTask = DownloadTask(
            url: testURL,
            destinationURL: createUniqueDestinationURL(),
            configuration: taskConfigure
        )

        let timeoutManager = ChunkDownloadManager(
            downloadTask: timeoutTask,
            configuration: shortTimeoutConfig,
            delegate: mockDelegate
        )

        let errorExpectation = XCTestExpectation(description: "Should timeout with short timeout interval")

        mockDelegate.onError = { _ in
            errorExpectation.fulfill()
        }

        let delayedResponse = MockURLProtocol.MockResponse(
            data: testData,
            statusCode: 200,
            headers: ["Content-Length": "\(testData.count)"],
            delay: 2.0
        )
        MockURLProtocol.register(mockResponse: delayedResponse, for: testURL)

        await timeoutManager.start()

        await fulfillment(of: [errorExpectation], timeout: 8.0)
        XCTAssertNotNil(mockDelegate.lastError)
    }

    // MARK: - Edge Case Tests

    func testDownloadManagerDeallocation() async {
        print("\(#function):\(#line)")

        var manager: ChunkDownloadManager? = ChunkDownloadManager(
            downloadTask: mockDownloadTask,
            configuration: mockConfiguration,
            delegate: mockDelegate
        )

        weak var weakManager = manager

        await manager?.start()

        manager = nil

        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        XCTAssertNil(weakManager, "Manager should be deallocated")
    }

    func testConcurrentStateChanges() async {
        print("\(#function):\(#line)")

        let expectation = XCTestExpectation(description: "Should handle concurrent state changes")

        let largeData = Data(count: 10 * 1024 * 1024) // 10MB
        setupMockResponse(with: largeData)

        var stateChangeCount = 0
        mockDelegate.onStateUpdate = { _ in
            stateChangeCount += 1
            if stateChangeCount >= 5 {
                expectation.fulfill()
            }
        }

        await downloadManager.start()

        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 100)
        await downloadManager.pause()

        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 100)
        await downloadManager.resume()

        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 100)
        await downloadManager.cancel()

        await fulfillment(of: [expectation], timeout: 10.0)
        XCTAssertGreaterThanOrEqual(stateChangeCount, 3, "Should handle concurrent state changes")
    }

    // MARK: - Memory and Performance Tests

    func testMemoryUsageWithLargeFile() async {
        print("\(#function):\(#line)")

        let completeExpectation = XCTestExpectation(description: "Large file download should complete efficiently")

        var progressUpdates: [(bytesReceived: Int64, totalBytes: Int64)] = []

        mockDelegate.onCompletion = { _ in
            completeExpectation.fulfill()
        }
        mockDelegate.onProgressUpdate = {
            progressUpdates.append($0)
        }

        let totalFileSize = 20 * 1024 * 1024 // 20MB
        let fileData = Data(count: totalFileSize)

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url, url == self.testURL else { return nil }

            if request.httpMethod == "HEAD" {
                return MockURLProtocol.MockResponse(
                    statusCode: 200,
                    headers: [
                        "Accept-Ranges": "bytes",
                        "Content-Length": "\(totalFileSize)",
                        "Content-Type": "application/octet-stream",
                    ]
                )
            }

            if let rangeHeader = request.allHTTPHeaderFields?["Range"] {
                return self.handleRangeRequest(rangeHeader: rangeHeader, data: fileData)
            }

            return MockURLProtocol.MockResponse(
                data: fileData,
                statusCode: 200,
                headers: [
                    "Content-Length": "\(totalFileSize)",
                    "Content-Type": "application/octet-stream",
                ]
            )
        }

        let initialMemory = getMemoryUsage()
        let startTime = CFAbsoluteTimeGetCurrent()

        await downloadManager.start()

        await fulfillment(of: [completeExpectation], timeout: 60.0)

        let finalMemory = getMemoryUsage()
        let downloadTime = CFAbsoluteTimeGetCurrent() - startTime
        let requestCount = MockURLProtocol.getRequestCount(for: testURL)
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        XCTAssertTrue(mockDelegate.stateUpdates.contains(.completed))

        let memoryIncrease = finalMemory - initialMemory
        let maxExpectedMemory = Int64(totalFileSize / 2)
        XCTAssertLessThan(memoryIncrease, maxExpectedMemory,
                          "Memory usage (\(memoryIncrease)) exceeded expected maximum (\(maxExpectedMemory))")
        XCTAssertTrue(mockDownloadTask.state == .completed, "下载完成了")
        XCTAssertGreaterThan(requestCount, 1, "Expected multiple requests for chunked download")

        XCTAssertGreaterThan(progressUpdates.count, 1, "Expected multiple progress updates")
        XCTAssertEqual(progressUpdates.last?.totalBytes, Int64(totalFileSize), "Final total bytes should match file size")
        XCTAssertEqual(progressUpdates.last?.bytesReceived, Int64(totalFileSize), "Should receive all bytes")

        print("Download completed:")
        print("- Time: \(String(format: "%.2f", downloadTime))s")
        print("- Memory increase: \(memoryIncrease) bytes")
        print("- Request count: \(requestCount)")
        print("- Progress updates: \(progressUpdates.count)")
    }

    func testChunkedDownloadBehavior() async {
        print("\(#function):\(#line)")

        let expectation = XCTestExpectation(description: "Chunked download test")

        MockURLProtocol.reset()

        let chunkSize = 1024 * 1024 // 1MB chunks
        let totalChunks = 5
        let totalSize = chunkSize * totalChunks

        var progressHistory: [Float] = []

        mockDelegate.onCompletion = { _ in
            expectation.fulfill()
        }
        mockDelegate.onProgressUpdate = { param in
            let (bytesReceived, totalBytes) = param
            let progress: Float = totalBytes > 0 ? Float(bytesReceived) / Float(totalBytes) : 0
            progressHistory.append(progress)
        }

        // HEAD响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(totalSize)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL, method: "HEAD")

        // 设置动态Range处理
        MockURLProtocol.setRequestHandler { request in
            if let rangeHeader = request.allHTTPHeaderFields?["Range"] {
                return self.handleRangeRequest(rangeHeader: rangeHeader, data: Data(count: totalSize))
            }
            return nil
        }

        await downloadManager.start()

        await fulfillment(of: [expectation], timeout: 30.0)
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)

        XCTAssertTrue(mockDelegate.stateUpdates.contains(.completed))

        XCTAssertGreaterThan(progressHistory.count, 1, "Expected multiple progress updates")
        print("progressHistory=>\(progressHistory)")
        for i in 1 ..< progressHistory.count {
            XCTAssertGreaterThanOrEqual(progressHistory[i], progressHistory[i - 1],
                                        "Progress should be monotonically increasing\(progressHistory)")
        }

        XCTAssertEqual(progressHistory.last ?? 0, 1.0, accuracy: 0.01, "Final progress should be 100% progressHistory=\(progressHistory)")

        print("Chunked download test completed:")
        print("- Progress updates: \(progressHistory.count)")
        print("- Final progress: \(String(format: "%.1f", (progressHistory.last ?? 0) * 100))%")
    }

    // 内存使用监控辅助函数
    private func getMemoryUsage() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0,
                          &count)
            }
        }

        if kerr == KERN_SUCCESS {
            return Int64(info.resident_size)
        } else {
            return 0
        }
    }

    func testChunkDownloadFail() async {
        print("\(#function):\(#line)")

        let expectation = XCTestExpectation(description: "Chunked download test")

        MockURLProtocol.reset()

        let chunkSize = 1024 * 1024 // 1MB chunks
        let totalChunks = 5
        let totalSize = chunkSize * totalChunks

        var progressHistory: [Float] = []

        mockDelegate.onProgressUpdate = { param in
            let (bytesReceived, totalBytes) = param
            let progress: Float = totalBytes > 0 ? Float(bytesReceived) / Float(totalBytes) : 0
            progressHistory.append(progress)
        }
        mockDownloadTask.taskConfigure.retryStrategy = .none
        mockConfiguration = ChunkConfiguration(chunkSize: Int64(chunkSize), maxConcurrentChunks: 2)
        downloadManager = ChunkDownloadManager(
            downloadTask: mockDownloadTask,
            configuration: mockConfiguration,
            delegate: mockDelegate
        )
        // HEAD响应
        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(totalSize)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL, method: "HEAD")

        // 设置动态Range处理
        MockURLProtocol.setRequestHandler { request in
            if let rangeHeader = request.allHTTPHeaderFields?["Range"] {
                if rangeHeader.starts(with: "bytes=2097152") { // 第2个失败
                    // 已经返回失败
                    expectation.fulfill()
                    return nil
                }
                let resp = self.handleRangeRequest(rangeHeader: rangeHeader, data: Data(count: totalSize))
                return resp
            }
            return nil
        }

        await downloadManager.start()

        await fulfillment(of: [expectation], timeout: 30.0)
        // 失败后能快速取消 5ms
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 5)
        let state = await downloadManager.state
        XCTAssertTrue(state.isFailed)
    }
}

// MARK: - Mock Classes

private class MockChunkDownloadManagerDelegate: ChunkDownloadManagerDelegate {
    var stateUpdates: [DownloadState] = []
    var progressUpdates: [(Int64, Int64)] = []
    var lastError: Error?
    var completionURL: URL?

    // Callback closures for better test control
    var onStateUpdate: ((DownloadState) -> Void)?
    var onProgressUpdate: (((Int64, Int64)) -> Void)?
    var onProgressDoubleUpdate: ((Double) -> Void)?
    var onError: ((Error) -> Void)?
    var onCompletion: ((URL) -> Void)?

    func chunkDownloadManager(_ manager: ChunkDownloadManager, task: DownloadTask, didUpdateProgress progress: (Int64, Int64)) {
        print("progress=>\(progress.0)/\(progress.1)")
        if progress.0 == -1 && progress.1 == -1 {
            print("异常了～")
        }
        progressUpdates.append(progress)
        onProgressUpdate?(progress)

        let progressRatio = progress.1 > 0 ? Double(progress.0) / Double(progress.1) : 0.0
        onProgressDoubleUpdate?(progressRatio)
    }

    func chunkDownloadManager(_ manager: ChunkDownloadManager, task: DownloadTask, didUpdateState state: DownloadState) {
        stateUpdates.append(state)
        onStateUpdate?(state)
    }

    func chunkDownloadManager(_ manager: ChunkDownloadManager, didCompleteWith task: DownloadTask) {
        completionURL = task.destinationURL
        onCompletion?(task.url)
    }

    func chunkDownloadManager(_ manager: ChunkDownloadManager, task: DownloadTask, didFailWithError error: any Error) {
        lastError = error
        onError?(error)
    }
}
