import Foundation

enum BoundedFileReadError: LocalizedError {
    case timedOut(String)
    case stillPending(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let name): "Reading \(name) timed out. Make the file available locally in Finder, then try again."
        case .stillPending(let name): "\(name) is still waiting on its file provider. Make it available locally before trying again."
        }
    }
}

/// File providers can block even `open(2)` indefinitely. A timeout abandons only a read-only
/// request, never an application mutation. An in-flight path has at most one worker, and a late
/// result is discarded; a future explicit retry obtains a new snapshot rather than stale bytes.
final class BoundedFileReader: @unchecked Sendable {
    static let shared = BoundedFileReader()
    typealias Loader = @Sendable (URL) throws -> Data?

    private final class Request: @unchecked Sendable {
        let completion = DispatchSemaphore(value: 0)
        var result: Result<Data?, Error>?
        var abandoned = false
    }

    private let lock = NSLock()
    private var pending: [String: Request] = [:]
    private let timeout: TimeInterval
    private let loader: Loader

    init(timeout: TimeInterval = 3, loader: @escaping Loader = BoundedFileReader.loadFile) {
        self.timeout = max(0.001, timeout)
        self.loader = loader
    }

    static func loadFile(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url, options: .uncached) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
    }

    var pendingReadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    func data(at url: URL) throws -> Data? {
        // Standardizing is lexical. Resolving a symlink here could itself contact a provider.
        let key = url.standardizedFileURL.path
        let request = Request()
        lock.lock()
        if pending[key] != nil {
            lock.unlock()
            throw BoundedFileReadError.stillPending(url.lastPathComponent)
        }
        pending[key] = request
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [self] in
            let result = Result { try loader(url) }
            lock.lock()
            if pending[key] === request { pending.removeValue(forKey: key) }
            if !request.abandoned { request.result = result }
            lock.unlock()
            request.completion.signal()
        }

        if request.completion.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            request.abandoned = true
            request.result = nil
            lock.unlock()
            throw BoundedFileReadError.timedOut(url.lastPathComponent)
        }
        lock.lock()
        let result = request.result
        lock.unlock()
        guard let result else { throw BoundedFileReadError.timedOut(url.lastPathComponent) }
        return try result.get()
    }

    func text(at url: URL) throws -> String? {
        guard let data = try data(at: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }
}
