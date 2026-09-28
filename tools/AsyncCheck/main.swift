import Foundation

/// No real servers, credentials, or paid model calls. The slow response waits
/// until URLSession cancels it; retry responses exercise cancellation in backoff.
final class StubProtocol: URLProtocol {
    static let lock = NSLock()
    static var starts = 0
    static var stops = 0
    static func reset() { lock.lock(); defer { lock.unlock() }; starts = 0; stops = 0 }
    static func counts() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (starts, stops) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.starts += 1
        let count = Self.starts
        Self.lock.unlock()
        if request.url!.path == "/slow" { return }
        let status = count == 1 ? 429 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.lock(); Self.stops += 1; Self.lock.unlock()
    }
}

@main struct AsyncChecks {
    static func main() async {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        func request(_ path: String) async -> Bool {
            do {
                _ = try await JevHTTP.postJSON([:], url: "https://test.invalid/" + path,
                                               headers: [:], budget: 15, stage: "test", session: session)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        func waitForStart() async {
            for _ in 0..<200 {
                if StubProtocol.counts().0 > 0 { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        StubProtocol.reset()
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await request("slow")
        }
        let preResult = await preCancelled.value
        check("cancel before request does not contact server", preResult && StubProtocol.counts().0 == 0)

        StubProtocol.reset()
        let inflight = Task { await request("slow") }
        await waitForStart()
        let start = Date()
        inflight.cancel()
        let inflightResult = await inflight.value
        check("in-flight cancellation stops URLSession without retry", inflightResult && StubProtocol.counts().0 == 1 && StubProtocol.counts().1 >= 1 && Date().timeIntervalSince(start) < 2)

        StubProtocol.reset()
        let backoff = Task { await request("retry") }
        await waitForStart()
        try? await Task.sleep(nanoseconds: 100_000_000)
        backoff.cancel()
        let backoffResult = await backoff.value
        check("cancel during rate-limit backoff does not retry", backoffResult && StubProtocol.counts().0 == 1)

        StubProtocol.reset()
        do {
            let result = try await JevHTTP.postJSON([:], url: "https://test.invalid/retry", headers: [:],
                                                   budget: 15, stage: "test", session: session)
            check("uncancelled rate-limit retry still succeeds", result["ok"] as? Bool == true && StubProtocol.counts().0 == 2)
        } catch { check("uncancelled rate-limit retry still succeeds", false) }
        print("\(4 - failures) async checks passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
