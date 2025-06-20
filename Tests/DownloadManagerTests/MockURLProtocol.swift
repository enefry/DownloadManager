import Foundation

class MockURLProtocol: URLProtocol {
    // MARK: - 模拟响应结构

    struct MockResponse {
        let data: Data?
        let statusCode: Int
        let headers: [String: String]
        let error: Error?
        let delay: TimeInterval
        let streamChunks: Bool // 是否分块流式传输

        init(data: Data? = nil,
             statusCode: Int = 200,
             headers: [String: String] = [:],
             error: Error? = nil,
             delay: TimeInterval = 0,
             streamChunks: Bool = true) {
            self.data = data
            self.statusCode = statusCode
            self.headers = headers
            self.error = error
            self.delay = delay
            self.streamChunks = streamChunks
        }
    }

    // MARK: - 私有存储属性

    private static var responses: [String: MockResponse] = [:]
    private static var rangeResponses: [String: MockResponse] = [:]
    private static var requestHandler: ((URLRequest) -> MockResponse?)?
    private static var progressCallback: ((URL, Int64, Int64) -> Void)?
    private static var requestCount: [URL: Int] = [:]
    private static var allRequests: [URLRequest] = []
    private static let queue = DispatchQueue(label: "MockURLProtocol", attributes: .concurrent)

    // MARK: - 公共接口方法

    /// 注册基于 URL 和 HTTP 方法的模拟响应
    static func register(mockResponse: MockResponse, for url: URL, method: String = "GET") {
        queue.async(flags: .barrier) {
            let key = "\(url.absoluteString)|\(method)"
            responses[key] = mockResponse
        }
    }

    /// 注册基于 Range 的特定响应
    static func register(mockResponse: MockResponse, for url: URL, range: String, method: String = "GET") {
        queue.async(flags: .barrier) {
            let key = "\(url.absoluteString)|\(method)|\(range)"
            rangeResponses[key] = mockResponse
        }
    }

    /// 设置动态请求处理器
    static func setRequestHandler(_ handler: @escaping (URLRequest) -> MockResponse?) {
        queue.async(flags: .barrier) {
            requestHandler = handler
        }
    }

    /// 设置进度回调
    static func setProgressCallback(_ callback: @escaping (URL, Int64, Int64) -> Void) {
        queue.async(flags: .barrier) {
            progressCallback = callback
        }
    }

    /// 获取指定 URL 的请求计数
    static func getRequestCount(for url: URL) -> Int {
        return queue.sync {
            return requestCount[url] ?? 0
        }
    }

    /// 获取所有请求历史
    static var requestHistory: [URLRequest] {
        return queue.sync {
            return allRequests
        }
    }

    /// 获取最后一个请求
    static var lastRequest: URLRequest? {
        return queue.sync {
            return allRequests.last
        }
    }

    /// 重置所有模拟数据
    static func reset() {
        queue.async(flags: .barrier) {
            responses.removeAll()
            rangeResponses.removeAll()
            requestHandler = nil
            progressCallback = nil
            requestCount.removeAll()
            allRequests.removeAll()
        }
    }

    // MARK: - URLProtocol 重写方法

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }

        // 记录请求历史和计数（线程安全）
        Self.queue.async(flags: .barrier) {
            Self.allRequests.append(self.request)
            Self.requestCount[url] = (Self.requestCount[url] ?? 0) + 1
        }

        // 异步处理响应
        Self.queue.async {
            var mockResponse: MockResponse?

            // 1. 优先使用动态请求处理器
            if let handler = Self.requestHandler {
                mockResponse = handler(self.request)
            }

            // 2. 检查 Range 请求的特定响应
            if mockResponse == nil, let rangeHeader = self.request.allHTTPHeaderFields?["Range"] {
                let method = self.request.httpMethod ?? "GET"
                let rangeKey = "\(url.absoluteString)|\(method)|\(rangeHeader)"
                mockResponse = Self.rangeResponses[rangeKey]
            }

            // 3. 查找基本响应
            if mockResponse == nil {
                let method = self.request.httpMethod ?? "GET"
                let key = "\(url.absoluteString)|\(method)"
                mockResponse = Self.responses[key]
            }

            guard let response = mockResponse else {
                DispatchQueue.main.async {
                    let error = NSError(domain: "MockError", code: -404, userInfo: [NSLocalizedDescriptionKey: "No mock response found"])
                    self.client?.urlProtocol(self, didFailWithError: error)
                }
                return
            }

            // 处理 Range 请求
            if let rangeHeader = self.request.allHTTPHeaderFields?["Range"]
                , response.data != nil
                , response.streamChunks {
                self.handleRangeRequest(mockResponse: response, rangeHeader: rangeHeader, url: url)
            } else {
                self.handleMockResponse(response, for: url)
            }
        }
    }

    override func stopLoading() {
        // 停止加载的实现
    }

    // MARK: - 私有方法

    /// 处理 Range 请求
    private func handleRangeRequest(mockResponse: MockResponse, rangeHeader: String, url: URL) {
        guard let data = mockResponse.data,
              let range = parseRangeHeader(rangeHeader, dataSize: Int64(data.count)) else {
            // Range 格式错误，返回 400
            let errorResponse = MockResponse(
                statusCode: 400,
                headers: [:],
                error: URLError(.badURL),
                delay: mockResponse.delay
            )
            handleMockResponse(errorResponse, for: url)
            return
        }

        let partialData = extractRangeData(from: data, range: range)
        let contentRange = "bytes \(range.start)-\(range.end)/\(data.count)"

        var headers = mockResponse.headers
        headers["Content-Range"] = contentRange
        headers["Content-Length"] = "\(partialData.count)"
        headers["Accept-Ranges"] = "bytes"

        let rangeResponse = MockResponse(
            data: partialData,
            statusCode: 206, // Partial Content
            headers: headers,
            error: mockResponse.error,
            delay: mockResponse.delay,
            streamChunks: mockResponse.streamChunks
        )

        handleMockResponse(rangeResponse, for: url)
    }

    /// 处理模拟响应
    private func handleMockResponse(_ response: MockResponse, for url: URL) {
        let processResponse = {
            DispatchQueue.main.async {
                self.processResponse(response, for: url)
            }
        }

        if response.delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + response.delay, execute: processResponse)
        } else {
            processResponse()
        }
    }

    /// 处理响应数据
    private func processResponse(_ response: MockResponse, for url: URL) {
        // 处理错误
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        // 创建 HTTP 响应
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)

        guard let data = response.data else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if response.streamChunks {
            sendStreamedData(data, for: url)
        } else {
            client?.urlProtocol(self, didLoad: data)

            // 发送进度更新（一次性完成）
            Self.queue.async {
                Self.progressCallback?(url, Int64(data.count), Int64(data.count))
            }

            client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// 分块发送数据
    private func sendStreamedData(_ data: Data, for url: URL) {
        let chunkSize = 8192 // 8KB chunks
        let totalSize = Int64(data.count)
        var offset = 0

        func sendNextChunk() {
            guard offset < data.count else {
                // 发送最终进度
                Self.queue.async {
                    Self.progressCallback?(url, totalSize, totalSize)
                }
                client?.urlProtocolDidFinishLoading(self)
                return
            }

            let remainingBytes = data.count - offset
            let currentChunkSize = min(chunkSize, remainingBytes)
            let chunk = data.subdata(in: offset ..< offset + currentChunkSize)

            client?.urlProtocol(self, didLoad: chunk)
            offset += currentChunkSize

            // 发送进度更新
            let bytesReceived = Int64(offset)
            Self.queue.async {
                Self.progressCallback?(url, bytesReceived, totalSize)
            }

            // 小延迟模拟网络传输
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) {
                sendNextChunk()
            }
        }

        sendNextChunk()
    }

    /// 解析 Range 头（支持多种格式）
    private func parseRangeHeader(_ rangeHeader: String, dataSize: Int64) -> (start: Int64, end: Int64)? {
        // 支持格式: "bytes=start-end", "bytes=start-", "bytes=-suffix"
        let cleanHeader = rangeHeader.replacingOccurrences(of: "bytes=", with: "")

        if cleanHeader.contains("-") {
            let parts = cleanHeader.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)

            if parts.count == 2 {
                let startStr = String(parts[0])
                let endStr = String(parts[1])

                if !startStr.isEmpty && !endStr.isEmpty {
                    // "start-end"
                    guard let start = Int64(startStr), let end = Int64(endStr) else { return nil }
                    return (start, min(end, dataSize - 1))
                } else if !startStr.isEmpty && endStr.isEmpty {
                    // "start-" (从start到文件末尾)
                    guard let start = Int64(startStr) else { return nil }
                    return (start, dataSize - 1)
                } else if startStr.isEmpty && !endStr.isEmpty {
                    // "-suffix" (最后suffix字节)
                    guard let suffix = Int64(endStr) else { return nil }
                    let start = max(0, dataSize - suffix)
                    return (start, dataSize - 1)
                }
            }
        }

        return nil
    }

    /// 提取 Range 数据
    private func extractRangeData(from data: Data, range: (start: Int64, end: Int64)) -> Data {
        let dataSize = Int64(data.count)

        // 确保范围有效
        let start = max(0, min(range.start, dataSize - 1))
        let end = max(start, min(range.end, dataSize - 1))

        let startIndex = Int(start)
        let endIndex = Int(end)
        let length = endIndex - startIndex + 1

        return data.subdata(in: startIndex ..< (startIndex + length))
    }
}

// MARK: - 便捷扩展

extension MockURLProtocol {
    /// 快速注册 JSON 响应
    static func registerJSON<T: Codable>(_ object: T, for url: URL, statusCode: Int = 200, delay: TimeInterval = 0) {
        do {
            let data = try JSONEncoder().encode(object)
            let response = MockResponse(
                data: data,
                statusCode: statusCode,
                headers: ["Content-Type": "application/json"],
                delay: delay
            )
            register(mockResponse: response, for: url)
        } catch {
            print("Failed to encode JSON: \(error)")
        }
    }

    /// 快速注册错误响应
    static func registerError(_ error: Error, for url: URL, delay: TimeInterval = 0) {
        let response = MockResponse(
            error: error,
            delay: delay
        )
        register(mockResponse: response, for: url)
    }

    /// 快速注册文件响应
    static func registerFile(at path: String, for url: URL, contentType: String? = nil, delay: TimeInterval = 0) {
        guard let data = FileManager.default.contents(atPath: path) else {
            registerError(URLError(.fileDoesNotExist), for: url, delay: delay)
            return
        }

        var headers: [String: String] = [:]
        if let contentType = contentType {
            headers["Content-Type"] = contentType
        }

        let response = MockResponse(
            data: data,
            headers: headers,
            delay: delay
        )
        register(mockResponse: response, for: url)
    }
}
