import Foundation

class MockURLProtocol: URLProtocol {
    // 存储所有注册的模拟响应
    static var mockResponses: [URL: MockResponse] = [:]

    // 模拟响应结构
    struct MockResponse {
        let data: Data
        let statusCode: Int
        let headers: [String: String]
        let error: Error?
        let delay: TimeInterval

        init(data: Data = Data(),
             statusCode: Int = 200,
             headers: [String: String] = [:],
             error: Error? = nil,
             delay: TimeInterval = 0) {
            self.data = data
            self.statusCode = statusCode
            self.headers = headers
            self.error = error
            self.delay = delay
        }
    }

    // 重置所有模拟响应
    static func reset() {
        mockResponses.removeAll()
    }

    // 注册模拟响应
    static func register(mockResponse: MockResponse, for url: URL) {
        mockResponses[url] = mockResponse
    }

    // 检查是否可以处理请求
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    // 规范化请求
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    // 开始加载
    override func startLoading() {
        guard let url = request.url,
              let mockResponse = MockURLProtocol.mockResponses[url] else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        // 创建响应
        let response = HTTPURLResponse(
            url: url,
            statusCode: mockResponse.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: mockResponse.headers
        )!

        // 处理 Range 请求
        if let rangeHeader = request.allHTTPHeaderFields?["Range"] {
            let range = parseRangeHeader(rangeHeader)
            let partialData = handleRangeRequest(data: mockResponse.data, range: range)
            sendResponse(response: response, data: partialData, error: mockResponse.error, delay: mockResponse.delay)
        } else {
            sendResponse(response: response, data: mockResponse.data, error: mockResponse.error, delay: mockResponse.delay)
        }
    }

    // 停止加载
    override func stopLoading() {
        // 实现停止加载的逻辑
    }

    // 发送响应
    private func sendResponse(response: HTTPURLResponse, data: Data, error: Error?, delay: TimeInterval) {
        if let error = error {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.client?.urlProtocol(self!, didFailWithError: error)
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    // 解析 Range 头
    private func parseRangeHeader(_ rangeHeader: String) -> (start: Int64, end: Int64)? {
        let pattern = "bytes=(\\d+)-(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: rangeHeader, range: NSRange(rangeHeader.startIndex..., in: rangeHeader)) else {
            return nil
        }

        let startRange = Range(match.range(at: 1), in: rangeHeader)!
        let endRange = Range(match.range(at: 2), in: rangeHeader)!

        let start = Int64(rangeHeader[startRange])!
        let end = Int64(rangeHeader[endRange])!

        return (start, end)
    }

    // 处理 Range 请求
    private func handleRangeRequest(data: Data, range: (start: Int64, end: Int64)?) -> Data {
        guard let range = range else { return data }

        let start = min(Int(range.start),data.count)
        let end = min(min(Int(range.end), data.count - 1),data.count)
        let length = end - start + 1
        return data.subdata(in: start..<(start + length))
    }
}
