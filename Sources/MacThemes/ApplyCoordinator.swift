import Foundation
import ThemeCore

struct ApplyResult: Codable, Equatable {
    enum State: String, Codable { case applied, pending, failed }
    let state: State
    let message: String
    static func applied(_ message: String) -> Self { .init(state: .applied, message: message) }
    static func pending(_ message: String) -> Self { .init(state: .pending, message: message) }
    static func failed(_ message: String) -> Self { .init(state: .failed, message: message) }
}

/// Coordinates an immutable request and journals results independently for each destination.
/// Existing adapter journals remain responsible for restoring original settings.
@MainActor final class ApplyCoordinator {
    static let fontDestinations: Set<Integration> = [.ghostty, .obsidian, .chatgpt]
    struct Record: Codable {
        var appliedTheme: Theme?
        var requestedTheme: Theme
        var result: ApplyResult
    }
    struct Report {
        let results: [Integration: ApplyResult]
        var allApplied: Bool { !results.isEmpty && results.values.allSatisfy { $0.state == .applied } }
        func summary(_ name: String) -> String {
            guard !results.isEmpty else { return "Enable an application to apply \(name)." }
            if allApplied { return "\(name) applied." }
            let applied = results.values.filter { $0.state == .applied }.count
            let pending = results.values.filter { $0.state == .pending }.count
            let failed = results.values.filter { $0.state == .failed }.count
            return "\(applied) applied · \(pending) pending · \(failed) failed. Check Setup & status."
        }
    }
    private let path: URL
    private(set) var records: [String: Record]
    init(root: URL) throws {
        path = root.appendingPathComponent("application-results.json")
        records = try BoundedFileReader.shared.data(at: path).map {
            try JSONDecoder().decode([String: Record].self, from: $0)
        } ?? [:]
    }
    func record(_ result: ApplyResult, theme: Theme, destination: Integration) throws {
        var updated = records
        updated[destination.rawValue] = Record(
            appliedTheme: result.state == .applied ? theme : records[destination.rawValue]?.appliedTheme,
            requestedTheme: theme, result: result)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: path, options: .atomic)
        records = updated
    }
    func clear(_ destination: Integration) throws {
        var updated = records
        updated.removeValue(forKey: destination.rawValue)
        try JSONEncoder().encode(updated).write(to: path, options: .atomic)
        records = updated
    }
    func run(theme: Theme, destinations: [Integration],
             installFont: () async throws -> Void,
             apply: (Integration, Theme) async throws -> ApplyResult,
             progress: (Integration, ApplyResult) -> Void) async throws -> Report {
        var results: [Integration: ApplyResult] = [:]
        var fontError: String?
        if theme.fontFamily != nil && !Set(destinations).isDisjoint(with: Self.fontDestinations) {
            do { try await installFont() } catch { fontError = error.localizedDescription }
        }
        for destination in destinations {
            // Persist intent first, so a crash cannot claim an unconfirmed application succeeded.
            let pending = ApplyResult.pending("Applying…")
            try record(pending, theme: theme, destination: destination)
            progress(destination, pending)
            let result: ApplyResult
            if Self.fontDestinations.contains(destination), let fontError {
                result = .failed(fontError)
            } else {
                do { result = try await apply(destination, theme) }
                catch { result = .failed(error.localizedDescription) }
            }
            try record(result, theme: theme, destination: destination)
            results[destination] = result
            progress(destination, result)
        }
        return Report(results: results)
    }
}
