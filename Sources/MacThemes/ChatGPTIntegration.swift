import AppKit
import Darwin
import ThemeCore

struct ChatGPTSettingBackup: Codable {
    var original: Data
    var applied: Data
    var previousApplied: Data?
}

struct ChatGPTBackup: Codable {
    var path: String
    var settings: [String: ChatGPTSettingBackup]

    func recording(_ desired: [String: Any], current: [String: Any]) throws -> ChatGPTBackup {
        var result = self
        for (key, value) in desired {
            let previous = try ChatGPTConfigEditor.encode(current[key])
            result.settings[key] = try ChatGPTSettingBackup(original: settings[key]?.original ?? previous,
                                                            applied: ChatGPTConfigEditor.encode(value), previousApplied: previous)
        }
        return result
    }

    func restoredSettings(current: [String: Any]) throws -> [String: Any] {
        var restored: [String: Any] = [:]
        for (key, setting) in settings {
            let value = try ChatGPTConfigEditor.encode(current[key])
            guard value == setting.applied || value == setting.original || value == setting.previousApplied else {
                throw ThemeError.message("ChatGPT's appearance was changed separately. Its backup is retained; restore stopped.")
            }
            restored[key] = try ChatGPTConfigEditor.decode(setting.original)
        }
        return restored
    }
}

/// The installed app caches appearance in memory and has no supported external
/// live-update endpoint. Keep the latest intent until it exits naturally.
enum ChatGPTPendingAction: Codable, Equatable {
    case apply(Theme)
    case restore
}

/// Uses the installed app's TOML editor against a disposable copy. Only the final,
/// checked config file is committed; no live app or conversation is controlled.
final class ChatGPTConfigEditor {
    private let directory: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var sequence = 0
    let source: String
    private(set) var settings: [String: Any] = [:]

    init(executable: URL, source: String) throws {
        self.source = source
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacThemes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try source.write(to: directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            process.executableURL = executable
            process.arguments = ["app-server", "--stdio"]
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = directory.path
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            _ = try request("initialize", ["clientInfo": ["name": "mac_themes", "version": "0.1"]])
            settings = try readSettings()
        } catch {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        sequence += 1
        var message = try JSONSerialization.data(withJSONObject: ["id": sequence, "method": method, "params": params])
        message.append(10)
        try input.fileHandleForWriting.write(contentsOf: message)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let end = buffer.firstIndex(of: 10) {
                let line = buffer[..<end]
                buffer.removeSubrange(...end)
                guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any], response["id"] as? Int == sequence else { continue }
                guard response["error"] == nil, let result = response["result"] as? [String: Any] else {
                    // Server errors can contain config contents; keep them out of the UI/log.
                    throw ThemeError.message("ChatGPT's configuration editor rejected the appearance change. Your settings were not replaced.")
                }
                return result
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) >= 0 else { throw ThemeError.message("Could not read ChatGPT's configuration editor.") }
            if descriptor.revents == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw ThemeError.message("ChatGPT's configuration editor stopped unexpectedly.") }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count < 8_000_000 else { throw ThemeError.message("ChatGPT's configuration response is too large.") }
        }
        throw ThemeError.message("ChatGPT's configuration editor timed out. Try again.")
    }

    private func readSettings() throws -> [String: Any] {
        let result = try request("config/read", ["includeLayers": true])
        let layers = result["layers"] as? [[String: Any]] ?? []
        guard let layer = layers.first(where: { item in
            guard let name = item["name"] as? [String: Any], name["type"] as? String == "user",
                  let path = name["file"] as? String else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath() == directory.appendingPathComponent("config.toml").resolvingSymlinksInPath()
        }), let config = layer["config"] as? [String: Any] else {
            throw ThemeError.message("Could not identify ChatGPT's appearance settings in its configuration.")
        }
        return try Self.normalizeLayerValue(config["desktop"] ?? [:]) as? [String: Any] ?? [:]
    }

    // This app-server build returns raw TOML layer numbers in serde's lossless
    // wrapper, whereas effective config returns ordinary JSON numbers.
    private static func normalizeLayerValue(_ value: Any) throws -> Any {
        if let object = value as? [String: Any] {
            if object.count == 1, let number = object["$serde_json::private::Number"] as? String {
                guard let value = try JSONSerialization.jsonObject(with: Data(number.utf8), options: .fragmentsAllowed) as? NSNumber else {
                    throw ThemeError.message("Unsupported number in ChatGPT's appearance settings.")
                }
                return value
            }
            return try object.mapValues(normalizeLayerValue)
        }
        if let array = value as? [Any] { return try array.map(normalizeLayerValue) }
        return value
    }

    func replacing(_ values: [String: Any]) throws -> String {
        let allowed = Set(["appearanceTheme", "appearanceLightChromeTheme", "appearanceDarkChromeTheme"])
        guard Set(values.keys).isSubset(of: allowed) else { throw ThemeError.message("Unsupported ChatGPT appearance key.") }
        let edits: [[String: Any]] = values.sorted(by: { $0.key < $1.key }).map {
            ["keyPath": "desktop.\($0.key)", "value": $0.value, "mergeStrategy": "replace"]
        }
        _ = try request("config/batchWrite", ["edits": edits, "filePath": directory.appendingPathComponent("config.toml").path])
        let check = try readSettings()
        for (key, value) in values {
            guard try Self.encode(check[key]) == Self.encode(value) else { throw ThemeError.message("ChatGPT's saved appearance did not match the requested palette.") }
        }
        return try String(contentsOf: directory.appendingPathComponent("config.toml"), encoding: .utf8)
    }

    static func encode(_ value: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed])
    }

    static func decode(_ value: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed])
    }

    static func themedSettings(_ theme: Theme, current: [String: Any]) -> [String: Any] {
        let light = theme.isLight
        let key = light ? "appearanceLightChromeTheme" : "appearanceDarkChromeTheme"
        var appearance = current[key] as? [String: Any] ?? [:]
        appearance["accent"] = theme.accent
        appearance["accentSource"] = "custom"
        appearance["surface"] = theme.background
        appearance["ink"] = theme.foreground
        appearance["semanticColors"] = ["diffAdded": theme.palette[2], "diffRemoved": theme.palette[1], "skill": theme.palette[5]]
        // Keep custom typography, contrast and translucency. In TOML, missing font
        // names represent the app's nullable/default font values.
        if appearance["fonts"] == nil { appearance["fonts"] = [String: String]() }
        if appearance["contrast"] == nil { appearance["contrast"] = light ? 45 : 60 }
        if appearance["opaqueWindows"] == nil { appearance["opaqueWindows"] = true }
        return ["appearanceTheme": light ? "light" : "dark", key: appearance]
    }

    /// Compatible with ChatGPT's Appearance → Import theme field. Importing this
    /// through the app's own settings is a manual live-update fallback.
    static func shareString(_ theme: Theme, current: [String: Any] = [:]) throws -> String {
        let key = theme.isLight ? "appearanceLightChromeTheme" : "appearanceDarkChromeTheme"
        var appearance = themedSettings(theme, current: current)[key] as! [String: Any]
        // The share schema uses JSON null for default fonts, whereas the TOML
        // config editor represents these defaults by absence.
        var fonts = appearance["fonts"] as? [String: Any] ?? [:]
        fonts["ui"] = fonts["ui"] ?? NSNull()
        fonts["code"] = fonts["code"] ?? NSNull()
        appearance["fonts"] = fonts
        let codeKey = theme.isLight ? "appearanceLightCodeThemeId" : "appearanceDarkCodeThemeId"
        let value: [String: Any] = ["variant": theme.isLight ? "light" : "dark", "theme": appearance, "codeThemeId": current[codeKey] as? String ?? (theme.id == "tokyo-night" && !theme.isLight ? "tokyo-night" : "codex")]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return "codex-theme-v1:" + String(decoding: data, as: UTF8.self)
    }
}

extension Integrations {
    private func chatGPTConfiguration() throws -> (URL, URL) {
        guard !running(.chatgpt) else { throw ThemeError.message("ChatGPT is still running. Its pending palette will be saved when it quits.") }
        guard let app = appURL(.chatgpt) else { throw ThemeError.message("This integration requires the newer ChatGPT app with custom Appearance settings.") }
        let executable = app.appendingPathComponent("Contents/Resources/codex")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ThemeError.message("This ChatGPT version does not have the supported configuration editor.") }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let path = state.chatgpt.map { URL(fileURLWithPath: $0.path) } ?? home.appendingPathComponent("config.toml").resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: path.path) else { throw ThemeError.message("Open ChatGPT once to create its settings, then retry.") }
        return (path, executable)
    }

    func restoreChatGPT() throws -> String {
        guard let backup = state.chatgpt else {
            let hadPending = state.chatgptPending != nil
            state.chatgptPending = nil
            if hadPending { try save() }
            return hadPending ? "Cancelled queued palette" : "No changes to restore"
        }
        try queueChatGPT(.restore)
        if running(.chatgpt) {
            return "Waiting · quit ChatGPT, then choose Restore again"
        }
        let (path, executable) = try chatGPTConfiguration()
        let source = try String(contentsOf: path, encoding: .utf8)
        let editor = try ChatGPTConfigEditor(executable: executable, source: source)
        let restored = try backup.restoredSettings(current: editor.settings)
        let updated = try editor.replacing(restored)
        try commitChatGPT(updated, original: source, to: path)
        state.chatgpt = nil
        state.chatgptPending = nil
        try save()
        return "Restored · reopen ChatGPT to load its appearance"
    }

    func queueChatGPT(_ action: ChatGPTPendingAction) throws {
        state.chatgptPending = action
        try save()
    }

    private func commitChatGPT(_ updated: String, original: String, to path: URL) throws {
        guard !running(.chatgpt), try String(contentsOf: path, encoding: .utf8) == original else {
            throw ThemeError.message("ChatGPT opened or its configuration changed before saving. Its pending palette is retained.")
        }
        try ManagedConfig.write(updated, to: path)
    }
}
