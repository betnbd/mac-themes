import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A repository locator parsed as data. No pasted text is ever passed to a shell.
public struct ThemeImportSource: Codable, Equatable, Sendable {
    public let owner: String
    public let repository: String
    public let reference: String?
    public let subdirectory: String
    public var repositoryURL: URL { URL(string: "https://github.com")!.appendingPathComponent(owner).appendingPathComponent(repository) }
    public var displayURL: String {
        repositoryURL.absoluteString + (reference.map { "/tree/\($0)" } ?? "") + (subdirectory.isEmpty ? "" : "/\(subdirectory)")
    }
    public var id: String {
        let slug = ([owner, repository] + subdirectory.split(separator: "/").map(String.init)).joined(separator: "-").lowercased().replacingOccurrences(of: "[^a-z0-9_.-]", with: "-", options: .regularExpression)
        let identity = owner.lowercased() + "/" + repository.lowercased() + "/" + (reference ?? "HEAD") + "/" + subdirectory
        let hash = SHA256.hash(data: Data(identity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "imported-" + String(slug.prefix(110)) + "-" + hash
    }
    public var name: String {
        var value = subdirectory.isEmpty ? repository : String(subdirectory.split(separator: "/").last!)
        if value.lowercased().hasPrefix("omarchy-") { value.removeFirst(8) }
        if value.lowercased().hasSuffix("-theme") { value.removeLast(6) }
        return value.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    }

    public static func parse(_ input: String) throws -> Self {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 4096 else { throw ThemeError.message("The theme install string is too long.") }
        // A deliberately small lexer: support quoted URLs, not shell substitutions, pipes, or flags.
        let words = try commandWords(trimmed)
        let address: String
        if words.count == 1 { address = words[0] }
        else if words.count == 2, words[0] == "omarchy-theme-install" { address = words[1] }
        else if words.count == 4, Array(words.prefix(3)) == ["omarchy", "theme", "install"] { address = words[3] }
        else { throw ThemeError.message("Paste a GitHub repository URL, omarchy-theme-install URL, or omarchy theme install URL. Shell scripts and chained commands are not imported.") }
        var value = address
        if value.hasPrefix("git@github.com:") { value = "https://github.com/" + value.dropFirst(15) }
        if value.hasPrefix("github.com/") { value = "https://" + value }
        guard let components = URLComponents(string: value), components.scheme == "https", components.host?.lowercased() == "github.com",
              components.user == nil, components.password == nil, components.port == nil, components.query == nil, components.fragment == nil else {
            throw ThemeError.message("Theme import currently supports public GitHub repositories. Use their HTTPS URL; authentication, other hosts, and URL options are not supported.")
        }
        let segments = components.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? "" }
        guard segments.count >= 2, validRepoPart(segments[0]), validRepoPart(segments[1]) else { throw ThemeError.message("The GitHub URL must identify an owner and repository.") }
        var repo = segments[1]
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        guard validRepoPart(repo) else { throw ThemeError.message("The repository name is invalid.") }
        var reference: String?, directory = ""
        if segments.count > 2 {
            guard segments.count >= 4, segments[2] == "tree", safeRelativePath(segments[3]) else { throw ThemeError.message("Use a repository URL or a GitHub /tree/branch/theme-folder URL.") }
            reference = segments[3]
            directory = segments.dropFirst(4).joined(separator: "/")
            guard directory.isEmpty || safeRelativePath(directory) else { throw ThemeError.message("The theme folder path is invalid.") }
        }
        return Self(owner: segments[0], repository: repo, reference: reference, subdirectory: directory)
    }

    private static func validRepoPart(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$", options: .regularExpression) != nil && value != "." && value != ".."
    }
    private static func commandWords(_ value: String) throws -> [String] {
        var words: [String] = [], word = "", quote: Character?
        for character in value {
            if "`$;|&<>\\\n\r\0".contains(character) { throw ThemeError.message("Paste just the repository URL or its Omarchy install command. Shell operators and substitutions are not accepted.") }
            if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" { quote = character }
            else if character.isWhitespace { if !word.isEmpty { words.append(word); word = "" } }
            else { word.append(character) }
        }
        guard quote == nil else { throw ThemeError.message("The theme install command contains an unclosed quote.") }
        if !word.isEmpty { words.append(word) }
        return words
    }
}

public struct ThemeWallpaper: Identifiable, Codable, Equatable, Sendable {
    public let relativePath: String
    public var id: String { relativePath }
    public var name: String { URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ") }
}

public struct ImportedTheme: Identifiable, Codable, Equatable, Sendable {
    public let theme: Theme
    public let source: ThemeImportSource
    public let revision: String
    /// Immutable generation directory, allowing an atomic manifest switch on update.
    public let version: String
    public let wallpapers: [ThemeWallpaper]
    public var selectedWallpaper: String?
    public let importedAt: Date
    public var id: String { theme.id }
    public func wallpaperURL(_ wallpaper: ThemeWallpaper, in libraryURL: URL) -> URL? {
        guard validImportID(id), safeRelativePath(version), !version.contains("/"),
              wallpapers.contains(wallpaper), safeRelativePath(wallpaper.relativePath) else { return nil }
        return libraryURL.appendingPathComponent(id).appendingPathComponent(version).appendingPathComponent(wallpaper.relativePath)
    }
    public func selectedWallpaperURL(in libraryURL: URL) -> URL? {
        guard let selectedWallpaper, let wallpaper = wallpapers.first(where: { $0.relativePath == selectedWallpaper }) else { return nil }
        return wallpaperURL(wallpaper, in: libraryURL)
    }
}

/// Converts only color values; terminal commands, includes, Lua, and editor extensions are ignored.
public enum ThemePaletteConverter {
    public static func convert(files: [String: String], id: String, name: String, lightMode: Bool = false) throws -> Theme {
        var colors: [String: String]
        if let content = files["colors.toml"] { colors = assignments(content) }
        else if let content = files["alacritty.toml"] { colors = alacritty(content) }
        else if let content = files["ghostty.conf"] { colors = ghostty(content) }
        else { throw ThemeError.message("No supported palette found. The theme needs colors.toml, alacritty.toml, or ghostty.conf in its root folder.") }
        for (canonical, old) in [("background", "bg"), ("foreground", "fg"), ("bright_foreground", "bright_fg"), ("dark_foreground", "dark_fg"), ("magenta", "purple"), ("bright_magenta", "bright_purple")] {
            if colors[canonical] == nil { colors[canonical] = colors[old] }
        }
        func color(_ keys: [String], fallback: String? = nil) throws -> String {
            for key in keys {
                if let value = colors[key] {
                    guard let parsed = normalizeColor(value) else { throw ThemeError.message("Invalid color for \(key). Expected a six-digit hex color.") }
                    return parsed
                }
            }
            if let fallback { return fallback }
            throw ThemeError.message("The theme palette is missing \(keys[0]).")
        }
        let background = try color(["background", "color0"]), foreground = try color(["foreground", "color7"])
        let names = ["red", "green", "yellow", "blue", "magenta", "cyan"]
        var normal: [String] = []
        for (i, key) in names.enumerated() { normal.append(try color([key, "color\(i + 1)"])) }
        let muted = try color(["muted", "color8", "dark_foreground"], fallback: foreground)
        var bright: [String] = []
        for (i, key) in names.enumerated() { bright.append(try color(["bright_" + key, "color\(i + 9)"], fallback: mix(normal[i], with: "#ffffff", fraction: 0.2))) }
        let brightForeground = try color(["bright_foreground", "color15"], fallback: foreground)
        let cursor = files["colors.toml"] == nil ? try color(["cursor"], fallback: brightForeground) : brightForeground
        let selection = try color(["selection", "selection_background", "color8"], fallback: background)
        let accent = try color(["accent", "blue", "color4"], fallback: normal[3])
        let inferred = ScriptLiteral.rgb(background).reduce(0, +) > 382 * 257 ? "light" : "dark"
        let mode = colors["mode"] ?? colors["theme_type"] ?? (lightMode ? "light" : inferred)
        guard mode == "light" || mode == "dark" else { throw ThemeError.message("Theme mode must be light or dark.") }
        let fallbackPalette = [background] + normal + [foreground, muted] + bright + [brightForeground]
        let semanticPalette = files["colors.toml"] != nil
        let palette = try (0..<16).map { index in
            // Omarchy's resolver makes color0/color7 authoritative aliases of the base
            // colors. Other explicit ANSI entries survive alongside semantic colors.
            if semanticPalette && (index == 0 || index == 7) { return fallbackPalette[index] }
            return try color(["color\(index)"], fallback: fallbackPalette[index])
        }
        return Theme(id: id, name: name, subtitle: "\(mode.capitalized) · Imported Omarchy", background: background, foreground: foreground, accent: accent, selection: selection, cursor: cursor, palette: palette, mode: mode)
    }
    private static func assignments(_ source: String) -> [String: String] {
        var result: [String: String] = [:], section = ""
        for original in source.split(whereSeparator: \.isNewline) {
            let line = original.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") { section = String(line[line.index(after: line.startIndex)..<end]); continue }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            var value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if let first = value.first, first == "\"" || first == "'", let end = value.dropFirst().firstIndex(of: first) { value = String(value[value.index(after: value.startIndex)..<end]) }
            else { value = value.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces) }
            result[section.isEmpty ? key : section + "." + key] = value
        }
        return result
    }
    private static func alacritty(_ source: String) -> [String: String] {
        let values = assignments(source)
        var result: [String: String] = [:]
        for key in ["background", "foreground"] { result[key] = values["colors.primary." + key] }
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        for (i, key) in names.enumerated() {
            result["color\(i)"] = values["colors.normal." + key]
            result["color\(i + 8)"] = values["colors.bright." + key]
        }
        result["selection"] = values["colors.selection.background"].flatMap(normalizeColor)
        result["cursor"] = values["colors.cursor.cursor"].flatMap(normalizeColor)
        return result
    }
    private static func ghostty(_ source: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in source.split(whereSeparator: \.isNewline) {
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces).components(separatedBy: " #")[0]
            if key == "palette", let inner = value.firstIndex(of: "="), let index = Int(value[..<inner].trimmingCharacters(in: .whitespaces)), (0...15).contains(index) {
                result["color\(index)"] = value[value.index(after: inner)...].trimmingCharacters(in: .whitespaces)
            } else if key == "background" || key == "foreground" { result[key] = value }
            else if key == "selection-background" { result["selection"] = value }
            else if key == "cursor-color" { result["cursor"] = value }
        }
        return result
    }
    private static func normalizeColor(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
        if value.hasPrefix("0x") { value = String(value.dropFirst(2)) }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { return nil }
        return "#" + value.lowercased()
    }
    private static func mix(_ start: String, with end: String, fraction: Double) -> String {
        let a = ScriptLiteral.rgb(start), b = ScriptLiteral.rgb(end)
        let channels: [String] = zip(a, b).map { pair in
            let startValue = Double(pair.0) / 257.0
            let endValue = Double(pair.1) / 257.0
            let blended = startValue * (1.0 - fraction) + endValue * fraction
            return String(format: "%02x", Int(blended.rounded()))
        }
        return "#" + channels.joined()
    }
}

public actor ThemeLibrary {
    public let directory: URL
    private var activeImports = Set<String>()
    // Injectable transport keeps parser/download/atomic-update tests independent of GitHub.
    typealias Fetch = @Sendable (URL, Int) async throws -> Data
    private let fetch: Fetch
    public init(directory: URL) { self.directory = directory; self.fetch = { try await ThemeHTTP.fetch($0, limit: $1) } }
    init(directory: URL, fetch: @escaping Fetch) { self.directory = directory; self.fetch = fetch }

    public func installedThemes() throws -> [ImportedTheme] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return try folders.filter { validImportID($0.lastPathComponent) }.compactMap { folder in
            let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { return nil }
            return try read(folder.lastPathComponent)
        }.sorted { $0.theme.name.localizedStandardCompare($1.theme.name) == .orderedAscending }
    }
    public func importTheme(_ input: String) async throws -> ImportedTheme { try await install(ThemeImportSource.parse(input)) }
    public func update(_ theme: ImportedTheme) async throws -> ImportedTheme {
        guard theme.id == theme.source.id, try read(theme.id) != nil else { throw ThemeError.message("That imported theme is no longer in the library.") }
        return try await install(theme.source)
    }
    public func selectWallpaper(_ relativePath: String?, themeID: String) throws -> ImportedTheme {
        guard var theme = try read(themeID) else { throw ThemeError.message("That imported theme is no longer in the library.") }
        guard relativePath == nil || theme.wallpapers.contains(where: { $0.relativePath == relativePath }) else { throw ThemeError.message("That wallpaper is not part of the imported theme.") }
        theme.selectedWallpaper = relativePath
        try save(theme)
        return theme
    }
    private func install(_ source: ThemeImportSource) async throws -> ImportedTheme {
        let id = source.id
        guard activeImports.insert(id).inserted else { throw ThemeError.message("This theme is already being downloaded.") }
        defer { activeImports.remove(id) }
        let commitData = try await fetch(apiURL(source, "commits", source.reference ?? "HEAD"), 2_000_000)
        let commit = try JSONDecoder().decode(GitCommit.self, from: commitData)
        guard commit.sha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { throw ThemeError.message("GitHub returned an invalid revision.") }
        var treeURL = URLComponents(url: apiURL(source, "git", "trees", commit.sha), resolvingAgainstBaseURL: false)!
        treeURL.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        let listing = try JSONDecoder().decode(GitTree.self, from: await fetch(treeURL.url!, 12_000_000))
        guard !listing.truncated else { throw ThemeError.message("This repository is too large to import safely. Use a smaller theme repository.") }
        let prefix = source.subdirectory.isEmpty ? "" : source.subdirectory + "/"
        let entries = listing.tree.filter { $0.path.hasPrefix(prefix) }.map { entry in
            GitEntry(path: String(entry.path.dropFirst(prefix.count)), mode: entry.mode, type: entry.type, size: entry.size)
        }
        let paletteNames = ["colors.toml", "alacritty.toml", "ghostty.conf"]
        guard let palette = paletteNames.compactMap({ name in entries.first { $0.path == name } }).first else { throw ThemeError.message("No palette found at that location. For a repository containing several themes, paste its GitHub /tree/branch/theme-folder URL.") }
        try validateEntry(palette, maxSize: 256_000)
        var imageEntries = entries.filter { $0.type == "blob" && ($0.path.hasPrefix("backgrounds/") || $0.path.hasPrefix("wallpapers/")) && ["png", "jpg", "jpeg", "webp", "heic", "tiff", "tif", "gif"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }
        imageEntries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard imageEntries.count <= 80 else { throw ThemeError.message("The theme has more than 80 backgrounds. Import a smaller theme folder.") }
        for image in imageEntries { try validateEntry(image, maxSize: 40_000_000) }
        guard imageEntries.reduce(0, { $0 + ($1.size ?? 0) }) <= 250_000_000 else { throw ThemeError.message("The theme's backgrounds exceed the 250 MB import limit.") }
        let uniquePaths = imageEntries.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() }
        guard Set(uniquePaths).count == uniquePaths.count else { throw ThemeError.message("The theme contains background filenames that collide on macOS.") }
        let paletteData = try await fetch(rawURL(source, revision: commit.sha, path: palette.path), 256_000)
        guard let text = String(data: paletteData, encoding: .utf8) else { throw ThemeError.message("The theme palette is not UTF-8 text.") }
        let theme = try ThemePaletteConverter.convert(files: [palette.path: text], id: id, name: source.name, lightMode: entries.contains { $0.path == "light.mode" && $0.type == "blob" && $0.mode != "120000" })
        try ensureDirectory(directory)
        let stage = directory.appendingPathComponent(".staging-" + UUID().uuidString)
        try ensureDirectory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        try paletteData.write(to: stage.appendingPathComponent(palette.path), options: .atomic)
        for entry in imageEntries {
            try Task.checkCancellation()
            let data = try await fetch(rawURL(source, revision: commit.sha, path: entry.path), min(40_000_000, entry.size ?? 0) + 1)
            guard data.count <= (entry.size ?? 0), Self.isImage(data) else { throw ThemeError.message("\(entry.path) is not a supported image, or is a Git LFS pointer. Store the image directly in the theme repository.") }
            let destination = stage.appendingPathComponent(entry.path)
            try ensureDirectory(destination.deletingLastPathComponent())
            try data.write(to: destination, options: .atomic)
        }
        // Retain a repository license when supplied, without executing or copying configuration code.
        if let license = entries.first(where: { ["LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING"].contains($0.path) && $0.mode != "120000" && ($0.size ?? Int.max) <= 256_000 }) {
            let data = try await fetch(rawURL(source, revision: commit.sha, path: license.path), 256_000)
            try data.write(to: stage.appendingPathComponent(license.path), options: .atomic)
        }
        try Task.checkCancellation()
        let existing = try read(id) // Read after awaits so a wallpaper selection made during the download survives.
        let wallpapers = imageEntries.map { ThemeWallpaper(relativePath: $0.path) }
        let selection: String?
        if let existing {
            if let old = existing.selectedWallpaper { selection = wallpapers.contains(where: { $0.relativePath == old }) ? old : wallpapers.first?.relativePath }
            else { selection = nil }
        } else { selection = wallpapers.first?.relativePath }
        let version = "version-" + UUID().uuidString
        let result = ImportedTheme(theme: theme, source: source, revision: commit.sha, version: version, wallpapers: wallpapers, selectedWallpaper: selection, importedAt: Date())
        let folder = directory.appendingPathComponent(id)
        try ensureDirectory(folder)
        let final = folder.appendingPathComponent(version)
        try FileManager.default.moveItem(at: stage, to: final)
        do { try save(result) } catch { try? FileManager.default.removeItem(at: final); throw error }
        // Previous versions remain valid for desktops currently using an older image path.
        return result
    }
    private func read(_ id: String) throws -> ImportedTheme? {
        guard validImportID(id) else { throw ThemeError.message("Invalid imported theme identifier.") }
        let path = directory.appendingPathComponent(id).appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let theme = try JSONDecoder().decode(ImportedTheme.self, from: Data(contentsOf: path))
        guard theme.id == id, theme.source.id == id, safeRelativePath(theme.version), !theme.version.contains("/"),
              theme.wallpapers.allSatisfy({ safeRelativePath($0.relativePath) }) else { throw ThemeError.message("The imported theme manifest is invalid.") }
        return theme
    }
    private func save(_ theme: ImportedTheme) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(theme).write(to: directory.appendingPathComponent(theme.id).appendingPathComponent("manifest.json"), options: .atomic)
    }
    private func validateEntry(_ entry: GitEntry, maxSize: Int) throws {
        guard entry.type == "blob", entry.mode == "100644" || entry.mode == "100755", safeRelativePath(entry.path), let size = entry.size, size > 0, size <= maxSize else { throw ThemeError.message("Theme file \(entry.path) is a link, has an unsafe path, or exceeds the download limit.") }
    }
    static func isImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) || bytes.starts(with: [0xff, 0xd8, 0xff]) { return true }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return true }
        if bytes.starts(with: [0x49, 0x49, 0x2a, 0]) || bytes.starts(with: [0x4d, 0x4d, 0, 0x2a]) { return true }
        if bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WEBP".utf8) { return true }
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8), ["heic", "heix", "mif1"].contains(String(bytes: bytes[8..<12], encoding: .ascii) ?? "") { return true }
        return false
    }
}

private struct GitCommit: Decodable { let sha: String }
private struct GitTree: Decodable { let tree: [GitEntry]; let truncated: Bool }
private struct GitEntry: Decodable { let path: String; let mode: String; let type: String; let size: Int? }
private func validImportID(_ id: String) -> Bool { id.range(of: "^imported-[A-Za-z0-9_.-]{1,160}$", options: .regularExpression) != nil }
private func safeRelativePath(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 240 }
}
private func ensureDirectory(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw ThemeError.message("The theme library contains an unexpected symbolic link.") }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
}
private func apiURL(_ source: ThemeImportSource, _ parts: String...) -> URL {
    (["repos", source.owner, source.repository] + parts).reduce(URL(string: "https://api.github.com")!) { $0.appendingPathComponent($1) }
}
private func rawURL(_ source: ThemeImportSource, revision: String, path: String) -> URL {
    ([source.owner, source.repository, revision] + (source.subdirectory.isEmpty ? [] : source.subdirectory.split(separator: "/").map(String.init)) + path.split(separator: "/").map(String.init)).reduce(URL(string: "https://raw.githubusercontent.com")!) { $0.appendingPathComponent($1) }
}

/// Cancels the transfer as soon as its bounded buffer is full, including responses without Content-Length.
private final class ThemeHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private var data = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var failure: Error?
    private init(limit: Int, continuation: CheckedContinuation<Data, Error>) { self.limit = limit; self.continuation = continuation }
    static func fetch(_ url: URL, limit: Int) async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = ThemeHTTP(limit: limit, continuation: continuation)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 180
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            var request = URLRequest(url: url)
            request.setValue("Mac-Themes/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            session.dataTask(with: request).resume()
            session.finishTasksAndInvalidate()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            failure = ThemeError.message(status == 403 || status == 429 ? "GitHub's download rate limit was reached. Try again later." : "GitHub could not download the theme (HTTP \(status)). Check that the repository and branch are public and exist.")
            completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= Int64(limit) else { failure = ThemeError.message("The theme download exceeds its size limit."); completionHandler(.cancel); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= limit else { failure = ThemeError.message("The theme download exceeds its size limit."); dataTask.cancel(); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", ["api.github.com", "raw.githubusercontent.com"].contains(request.url?.host ?? "") else { failure = ThemeError.message("GitHub redirected the theme to an unsupported download host."); completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = failure ?? error { continuation?.resume(throwing: error) } else { continuation?.resume(returning: data) }
        continuation = nil
    }
}
