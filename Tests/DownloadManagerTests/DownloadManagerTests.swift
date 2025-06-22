import Combine
@testable import DownloadManager // 确保你的模块名正确
import Foundation
import XCTest

// MARK: - MockDownloadTask

extension DownloadTask {
    func setDownloadedBytes(_ bytes: Int64) {
        downloadedBytes = bytes
        progressSubject.send(DownloadProgress(downloadedBytes: bytes, totalBytes: totalBytes))
    }

    func setTotalBytes(_ bytes: Int64) {
        totalBytes = bytes
        progressSubject.send(DownloadProgress(downloadedBytes: downloadedBytes, totalBytes: bytes))
    }

    func setState(_ state: DownloadState) {
        stateSubject.send(state)
    }
}

// MARK: - MockChunkDownloadManager

actor MockChunkDownloadManager: ChunkDownloadManagerProtocol {
    class DelegateProxy: ChunkDownloadManagerDelegate, @unchecked Sendable {
        weak var delegate: ChunkDownloadManagerDelegate?
        weak var mgr: ChunkDownloadManagerProtocol?

        func chunkDownloadManager(_ manager: any ChunkDownloadManagerProtocol, didCompleteWith task: DownloadTask) {
            if let delegate = delegate, let mgr = mgr {
                delegate.chunkDownloadManager(mgr, didCompleteWith: task)
            }
        }

        nonisolated func chunkDownloadManager(_ manager: any ChunkDownloadManagerProtocol, task: DownloadTask, didUpdateProgress progress: DownloadProgress) {
            if let delegate = delegate, let mgr = mgr {
                delegate.chunkDownloadManager(mgr, task: task, didUpdateProgress: progress)
            }
        }

        nonisolated func chunkDownloadManager(_ manager: any ChunkDownloadManagerProtocol, task: DownloadTask, didUpdateState state: DownloadState) {
            if let delegate = delegate, let mgr = mgr {
                delegate.chunkDownloadManager(mgr, task: task, didUpdateState: state)
            }
        }

        nonisolated func chunkDownloadManager(_ manager: any ChunkDownloadManagerProtocol, task: DownloadTask, didFailWithError error: any Error) {
            if let delegate = delegate, let mgr = mgr {
                delegate.chunkDownloadManager(mgr, task: task, didFailWithError: error)
            }
        }
    }

    var chunkAvailable: Bool
    var downloadTask: DownloadTask
    var configuration: ChunkConfiguration
    let mgr: ChunkDownloadManager
    let proxy: DelegateProxy
    weak var delegate: ChunkDownloadManagerDelegate?

    var startCallCount = 0
    var pauseCallCount = 0
    var resumeCallCount = 0
    var cancelCallCount = 0
    var cleanupCallCount = 0

    var _state: DownloadState = .initialed
    var state: DownloadState {
        get async {
            _state
        }
    }

    init(downloadTask: DownloadTask, configuration: ChunkConfiguration, delegate: ChunkDownloadManagerDelegate?) {
        self.downloadTask = downloadTask
        self.configuration = configuration
        self.delegate = delegate
        chunkAvailable = false
        let proxy = DelegateProxy()
        self.proxy = proxy
        mgr = ChunkDownloadManager(downloadTask: downloadTask, configuration: configuration, delegate: proxy)

        proxy.delegate = delegate
        proxy.mgr = self
    }

    func start() async {
        startCallCount += 1
        _state = .downloading
        await mgr.start()
    }

    func pause() async {
        pauseCallCount += 1
        _state = .paused
        await mgr.pause()
    }

    func resume() async {
        resumeCallCount += 1
        _state = .downloading
        await mgr.resume()
    }

    func cancel() async {
        cancelCallCount += 1
        _state = .cancelled
        await mgr.cancel()
    }

    func cleanup() async {
        cleanupCallCount += 1
        await mgr.cleanup()
    }

    func simulateProgress(downloaded: Int64, total: Int64) async {
        downloadTask.setDownloadedBytes(downloaded)
        downloadTask.setTotalBytes(total)
        delegate?.chunkDownloadManager(self, task: downloadTask, didUpdateProgress: DownloadProgress(downloadedBytes: downloaded, totalBytes: total))
    }

    func simulateStateChange(_ state: DownloadState) async {
        _state = state
        downloadTask.setState(state)
        delegate?.chunkDownloadManager(self, task: downloadTask, didUpdateState: state)
        if state.isFinished {
            delegate?.chunkDownloadManager(self, didCompleteWith: downloadTask)
        }
    }

    func simulateFailure(_ error: Error) async {
        _state = .failed(DownloadError.from(error))
        downloadTask.setState(.failed(DownloadError.from(error)))
        delegate?.chunkDownloadManager(self, task: downloadTask, didFailWithError: error)
    }
}

// MARK: - MockDownloadPersistenceManager

class MockDownloadPersistenceManager: DownloadPersistenceManagerProtocol {
    var savedTasks: [DownloadTask] = []
    var loadTasksCallCount = 0
    var saveTasksCallCount = 0
    var clearTasksCallCount = 0
    var shouldFailOnSave = false
    var shouldFailOnLoad = false
    
    func setup(configure: DownloadManagerConfiguration) async {
    }

    func saveTasks(_ tasks: [DownloadTask]) async throws {
        saveTasksCallCount += 1
        if shouldFailOnSave {
            throw DownloadError.fileSystemError("Mock save failure")
        }
        savedTasks = tasks
    }

    func loadTasks() async throws -> [DownloadTask] {
        loadTasksCallCount += 1
        if shouldFailOnLoad {
            throw DownloadError.fileSystemError("Mock load failure")
        }
        return savedTasks
    }

    func clearTasks() async throws {
        clearTasksCallCount += 1
        savedTasks.removeAll()
    }
}

// MARK: - MockNetworkMonitor

class MockNetworkMonitor: NetworkMonitor {
    private let _statusPublisher = CurrentValueSubject<NetworkStatus, Never>(.connected(.wifi))
    override var statusPublisher: AnyPublisher<NetworkStatus, Never> {
        _statusPublisher.eraseToAnyPublisher()
    }

    override var status: NetworkStatus {
        _statusPublisher.value
    }

    override var isConnected: Bool {
        if case .connected = _statusPublisher.value { return true } else { return false }
    }

    override var isCellular: Bool {
        if case let .connected(type) = _statusPublisher.value, type == .cellular { return true } else { return false }
    }

    override var isWifi: Bool {
        if case let .connected(type) = _statusPublisher.value, type == .wifi { return true } else { return false }
    }

    override var currentNetworkType: NetworkType {
        if case let .connected(type) = _statusPublisher.value { return type } else { return .unknown }
    }

    private let _networkTypePublisher = CurrentValueSubject<NetworkType, Never>(.wifi)
    override var networkTypePublisher: AnyPublisher<NetworkType, Never> {
        _networkTypePublisher.eraseToAnyPublisher()
    }

    override func startMonitoring() {
        // Mock implementation
    }

    override func stopMonitoring() {
        // Mock implementation
    }

    func simulateNetworkStatus(_ status: NetworkStatus) {
        _statusPublisher.send(status)
        if case let .connected(type) = status {
            _networkTypePublisher.send(type)
        } else {
            _networkTypePublisher.send(.unknown)
        }
    }
}

// MARK: - DownloadManagerTests

final class DownloadManagerTests: XCTestCase {
    var downloadManager: DownloadManager!
    var mockPersistenceManager: MockDownloadPersistenceManager!
    var mockNetworkMonitor: MockNetworkMonitor!
    var cancellables: Set<AnyCancellable>!
    let taskConfigure = DownloadTaskConfiguration(chunkSize: 1024 * 128, maxConcurrentChunks: 4, protocolClasses: [NSStringFromClass(MockURLProtocol.self)])

    override func setUp() async throws {
        try await super.setUp()
        cancellables = Set<AnyCancellable>()
        URLProtocol.registerClass(MockURLProtocol.self)
        setupDefaultMockResponse()

        mockPersistenceManager = MockDownloadPersistenceManager()
        mockNetworkMonitor = MockNetworkMonitor()

        let config = DownloadManagerConfiguration(
            maxConcurrentDownloads: 2,
            defaultTaskConfiguration: taskConfigure,
            chunkDownloadManagerFactory: { downloadTask, configuration, delegate in
                MockChunkDownloadManager(downloadTask: downloadTask, configuration: configuration, delegate: delegate)
            },
            downloadPersistenceFactory: {
                self.mockPersistenceManager
            }
        ) {
            self.mockNetworkMonitor
        }

        downloadManager = DownloadManager(configuration: config)
        await downloadManager.waitForStartup()
        await Task.yield()
    }

    private let testData = Data(count: 128)
    private let testURL = URL(string: "https://example.com/test.file")!

    private func setupDefaultMockResponse() {
        MockURLProtocol.reset()

        let headResponse = MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(testData.count)",
            ]
        )
        MockURLProtocol.register(mockResponse: headResponse, for: testURL, method: "HEAD")

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

    override func tearDown() async throws {
        downloadManager.removeAll()
        cancellables.removeAll()
        downloadManager = nil
        mockPersistenceManager = nil
        mockNetworkMonitor = nil
        try await super.tearDown()
    }

    // MARK: - Task Creation Tests

    func testCreateDownloadTask() async throws {
        let url = testURL
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("file1.zip")

        let task = await downloadManager.download(url: url, destination: destination, configuration: nil)
        XCTAssertNotNil(task.identifier)
        XCTAssertEqual(task.url, url)
        XCTAssertEqual(task.destinationURL, destination)

        let expectation = XCTestExpectation(description: "Task created in state")
        downloadManager.allTasksPublisher
            .sink { tasks in
                if tasks.contains(where: { $0.identifier == task.identifier }) {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(mockPersistenceManager.saveTasksCallCount, 1)
        XCTAssertTrue(mockPersistenceManager.savedTasks.contains(where: { $0.identifier == task.identifier }))
    }

    func testDuplicateTaskCreation() async throws {
        let url = testURL
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("duplicate.zip")

        let task1 = await downloadManager.download(url: url, destination: destination, configuration: nil)
        let task2 = await downloadManager.download(url: url, destination: destination, configuration: nil)

        XCTAssertEqual(task1.identifier, task2.identifier)
        XCTAssertTrue(task1 === task2)

        let exp = XCTestExpectation(description: "Actor only creates one task")
        downloadManager.allTasksPublisher
            .sink { tasks in
                if tasks.count == 1 && tasks.first?.identifier == task1.identifier {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)
        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertEqual(downloadManager.allTasks.count, 1)
    }

    func testCreateTaskWithCustomConfiguration() async throws {
        let customConfig = DownloadTaskConfiguration(
            headers: ["Authorization": "Bearer token"],
            chunkSize: 512,
            maxConcurrentChunks: 2
        )

        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("custom.zip"),
            configuration: customConfig
        )

        XCTAssertEqual(task.taskConfigure.headers["Authorization"], "Bearer token")
        XCTAssertEqual(task.taskConfigure.chunkSize, 512)
        XCTAssertEqual(task.taskConfigure.maxConcurrentChunks, 2)
    }

    // MARK: - Task Management Tests

    func testFindTaskByIdentifier() async throws {
        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("find.zip"),
            configuration: nil
        )

        await Task.yield()

        let foundTask = downloadManager.task(withIdentifier: task.identifier)
        XCTAssertNotNil(foundTask)
        XCTAssertEqual(foundTask?.identifier, task.identifier)

        let notFoundTask = downloadManager.task(withIdentifier: "non-existent")
        XCTAssertNil(notFoundTask)
    }

    func testFindTaskByURL() async throws {
        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("find_url.zip"),
            configuration: nil
        )

        await Task.yield()

        let foundTask = downloadManager.task(withURL: testURL)
        XCTAssertNotNil(foundTask)
        XCTAssertEqual(foundTask?.identifier, task.identifier)

        let notFoundTask = downloadManager.task(withURL: URL(string: "https://notfound.com")!)
        XCTAssertNil(notFoundTask)
    }

    func testRemoveTaskByIdentifier() async throws {
        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("remove.zip"),
            configuration: nil
        )

        await Task.yield()
        XCTAssertEqual(downloadManager.allTasks.count, 1)

        downloadManager.remove(withIdentifier: task.identifier)

        let expectation = XCTestExpectation(description: "Task removed")
        downloadManager.allTasksPublisher
            .sink { tasks in
                if tasks.isEmpty {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(downloadManager.allTasks.count, 0)
    }

    func testRemoveTaskByURL() async throws {
        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("remove_url.zip"),
            configuration: nil
        )

        await Task.yield()
        XCTAssertEqual(downloadManager.allTasks.count, 1)

        downloadManager.remove(withURL: testURL)

        let expectation = XCTestExpectation(description: "Task removed by URL")
        downloadManager.allTasksPublisher
            .sink { tasks in
                if tasks.isEmpty {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(downloadManager.allTasks.count, 0)
    }

    func testRemoveTaskByObject() async throws {
        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("remove_obj.zip"),
            configuration: nil
        )

        await Task.yield()
        XCTAssertEqual(downloadManager.allTasks.count, 1)

        downloadManager.remove(task: task)

        let expectation = XCTestExpectation(description: "Task removed by object")
        downloadManager.allTasksPublisher
            .sink { tasks in
                if tasks.isEmpty {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(downloadManager.allTasks.count, 0)
    }

    // MARK: - Task Control Tests

    func testPauseTask() async throws {
        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("pause.zip"),
            configuration: nil
        )

        await Task.yield()
        downloadManager.pause(withIdentifier: task.identifier)
        await Task.yield()

        // Mock chunk manager should have been called
        // We can't directly test this without exposing internal state
        // But we can verify the task still exists
        XCTAssertNotNil(downloadManager.task(withIdentifier: task.identifier))
    }

    func testPauseTaskByObject() async throws {
        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("pause_obj.zip"),
            configuration: nil
        )

        await Task.yield()
        downloadManager.pause(task: task)
        await Task.yield()

        XCTAssertNotNil(downloadManager.task(withIdentifier: task.identifier))
    }

    func testResumeTask() async throws {
        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("resume.zip"),
            configuration: nil
        )

        await Task.yield()
        downloadManager.pause(withIdentifier: task.identifier)
        await Task.yield()
        downloadManager.resume(withIdentifier: task.identifier)
        await Task.yield()

        XCTAssertNotNil(downloadManager.task(withIdentifier: task.identifier))
    }

    func testResumeTaskByObject() async throws {
        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("resume_obj.zip"),
            configuration: nil
        )

        await Task.yield()
        downloadManager.pause(task: task)
        await Task.yield()
        downloadManager.resume(task: task)
        await Task.yield()

        XCTAssertNotNil(downloadManager.task(withIdentifier: task.identifier))
    }

    func testCancelTask() async throws {
        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("cancel.zip"),
            configuration: nil
        )

        await Task.yield()
        downloadManager.cancel(withIdentifier: task.identifier)
        await Task.yield()

        XCTAssertNotNil(downloadManager.task(withIdentifier: task.identifier))
    }

    func testCancelTaskByObject() async throws {
        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("cancel_obj.zip"),
            configuration: nil
        )

        await Task.yield()
        downloadManager.cancel(task: task)
        await Task.yield()

        XCTAssertNotNil(downloadManager.task(withIdentifier: task.identifier))
    }

    // MARK: - Bulk Operations Tests

    func testPauseAllTasks() async throws {
        let task1 = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("pause_all_1.zip"),
            configuration: nil
        )

        let task2 = await downloadManager.download(
            url: URL(string: "https://example.com/test2.file")!,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("pause_all_2.zip"),
            configuration: nil
        )

        await Task.yield()
        XCTAssertEqual(downloadManager.allTasks.count, 2)

        downloadManager.pauseAll()
        await Task.yield()

        XCTAssertEqual(downloadManager.allTasks.count, 2)
    }

    func testResumeAllTasks() async throws {
        let task1 = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("resume_all_1.zip"),
            configuration: nil
        )

        let task2 = await downloadManager.download(
            url: URL(string: "https://example.com/test2.file")!,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("resume_all_2.zip"),
            configuration: nil
        )

        await Task.yield()
        downloadManager.pauseAll()
        await Task.yield()
        downloadManager.resumeAll()
        await Task.yield()

        XCTAssertEqual(downloadManager.allTasks.count, 2)
    }

    func testCancelAllTasks() async throws {
        let task1 = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("cancel_all_1.zip"),
            configuration: nil
        )

        let task2 = await downloadManager.download(
            url: URL(string: "https://example.com/test2.file")!,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("cancel_all_2.zip"),
            configuration: nil
        )

        await Task.yield()
        XCTAssertEqual(downloadManager.allTasks.count, 2)

        downloadManager.cancelAll()
        await Task.yield()

        XCTAssertEqual(downloadManager.allTasks.count, 2)
    }

    func testRemoveAllTasks() async throws {
        let task1 = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("remove_all_1.zip"),
            configuration: nil
        )

        let task2 = await downloadManager.download(
            url: URL(string: "https://example.com/test2.file")!,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("remove_all_2.zip"),
            configuration: nil
        )

        await Task.yield()
        XCTAssertEqual(downloadManager.allTasks.count, 2)

        downloadManager.removeAll()

        let expectation = XCTestExpectation(description: "All tasks removed")
        downloadManager.allTasksPublisher
            .sink { tasks in
                if tasks.isEmpty {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(downloadManager.allTasks.count, 0)
    }

    func testRemoveAllFinishedTasks() async throws {
        let task1 = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("finished_1.zip"),
            configuration: nil
        )

        let task2 = await downloadManager.download(
            url: URL(string: "https://example.com/test2.file")!,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("finished_2.zip"),
            configuration: nil
        )

        await Task.yield()

        // Simulate one task as completed
//        task1.setState(.completed)

        downloadManager.removeAllFinished()

        // Wait for the operation to complete
        await Task.yield()

        // Should still have the non-finished task
        XCTAssertGreaterThan(downloadManager.allTasks.count, 0)
    }

    // MARK: - Concurrent Downloads Tests

    func testMaxConcurrentDownloads() async throws {
        let initialMax = downloadManager.maxConcurrentDownloads
        XCTAssertEqual(initialMax, 4) // Set in configuration

        downloadManager.maxConcurrentDownloads = 5
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        XCTAssertEqual(downloadManager.maxConcurrentDownloads, 5)

        // Test invalid values
        downloadManager.maxConcurrentDownloads = 0
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        XCTAssertEqual(downloadManager.maxConcurrentDownloads, 5) // Should remain unchanged

        downloadManager.maxConcurrentDownloads = -1
        try? await Task.sleep(nanoseconds: UInt64(kMillisecondScale) * 10)
        XCTAssertEqual(downloadManager.maxConcurrentDownloads, 5) // Should remain unchanged
    }

    func testActiveTaskCount() async throws {
        XCTAssertEqual(downloadManager.activeTaskCount, 0)

        let expectation = XCTestExpectation(description: "Active task count updated")
        downloadManager.activeTaskCountPublisher
            .sink { count in
                if count > 0 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("active.zip"),
            configuration: nil
        )

        await fulfillment(of: [expectation], timeout: 1.0)
    }

    // MARK: - Task Priority Tests

    func testInsertTaskAtFront() async throws {
        let task1 = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("priority_1.zip"),
            configuration: nil
        )

        let task2 = await downloadManager.download(
            url: URL(string: "https://example.com/test2.file")!,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("priority_2.zip"),
            configuration: nil
        )

        await Task.yield()

        downloadManager.insert(withIdentifier: task2.identifier)
        await Task.yield()

        // Both tasks should still exist
        XCTAssertEqual(downloadManager.allTasks.count, 2)
    }

    func testInsertTaskByObject() async throws {
        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("insert_obj.zip"),
            configuration: nil
        )

        await Task.yield()

        downloadManager.insert(task: task)
        await Task.yield()

        XCTAssertEqual(downloadManager.allTasks.count, 1)
    }

    // MARK: - Network Monitoring Tests

    func testNetworkStatusChange() async throws {
        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("network.zip"),
            configuration: nil
        )

        await Task.yield()

        // Simulate network change to cellular
        mockNetworkMonitor.simulateNetworkStatus(.connected(.cellular))
        await Task.yield()

        // Simulate network disconnection
        mockNetworkMonitor.simulateNetworkStatus(.disconnected)
        await Task.yield()

        // Simulate network reconnection
        mockNetworkMonitor.simulateNetworkStatus(.connected(.wifi))
        await Task.yield()

        XCTAssertNotNil(downloadManager.task(withIdentifier: task.identifier))
    }

    // MARK: - Persistence Tests

    func testPersistenceOnTaskCreation() async throws {
        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("persist.zip"),
            configuration: nil
        )

        await Task.yield()

        XCTAssertGreaterThan(mockPersistenceManager.saveTasksCallCount, 0)
        XCTAssertTrue(mockPersistenceManager.savedTasks.contains(where: { $0.identifier == task.identifier }))
    }

    func testPersistenceFailure() async throws {
        mockPersistenceManager.shouldFailOnSave = true

        let task = await downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("persist_fail.zip"),
            configuration: nil
        )

        await Task.yield()

        // Task should still be created even if persistence fails
        XCTAssertNotNil(downloadManager.task(withIdentifier: task.identifier))
    }

    // MARK: - Callback Tests

    func testDownloadWithCompletion() async throws {
        let expectation = XCTestExpectation(description: "Download completion callback")

        downloadManager.download(
            url: testURL,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("callback.zip"),
            configuration: nil
        ) { task in
            XCTAssertNotNil(task)
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 1.0)
    }

    // MARK: - Wait for Tasks Tests

//
//    func testWaitForAllTasks() async throws {
//        let task1 = await downloadManager.download(
//            url: testURL,
//            destination: FileManager.default.temporaryDirectory.appendingPathComponent("wait_1.zip"),
//            configuration: nil
//        )
//
//        let task2 = await downloadManager.download(
//            url: URL(string: "https://example.com/test2.file")!,
//            destination: FileManager.default.temporaryDirectory.appendingPathComponent("wait_2.zip"),
//            configuration: nil
//        )
//
//        await Task.yield()
//
//        // Simulate tasks completion
//        task1.setState(.completed)
//        task2.setState(.completed)
//
//        // This should not throw or hang
//        try await downloadManager.waitForAllTasks()
//    }
}
