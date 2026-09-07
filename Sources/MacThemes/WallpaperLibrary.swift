import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import ThemeCore

/// User choices are independent of bundled resources and downloaded theme versions.
actor WallpaperLibrary {
    struct Item: Codable, Sendable {
        let id: String
        let file: String
        let name: String
    }
    struct Entry: Codable, Sendable {
        var added: [Item] = []
        var hidden: Set<String> = []
    }
    typealias Snapshot = [String: Entry]
    private let directory: URL
    private let journal: URL
    private var state: Snapshot

    init(root: URL) throws {
        directory = root.appendingPathComponent("CustomWallpapers")
        journal = root.appendingPathComponent("wallpaper-library.json")
        state = try BoundedFileReader.shared.data(at: journal).map { try JSONDecoder().decode(Snapshot.self, from: $0) } ?? [:]
        guard state.values.flatMap(\.added).allSatisfy({
            $0.file.range(of: "^[a-f0-9]{64}\\.[a-z0-9]+$", options: .regularExpression) != nil && $0.id == "custom:" + $0.file.components(separatedBy: ".")[0]
        }) else { throw ThemeError.message("The custom wallpaper library needs review. Its files were kept.") }
    }

    func snapshot() -> Snapshot { state }

    private func save(_ updated: Snapshot) throws {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: journal, options: .atomic)
        state = updated
    }

    func add(_ urls: [URL], to themeID: String) throws -> [String] {
        var entry = state[themeID] ?? Entry(), ids: [String] = [], created: [URL] = []
        do {
            for url in urls {
                guard url.isFileURL else { throw ThemeError.message("Drop image files from Finder.") }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber, size.intValue <= 40_000_000,
                      let data = try BoundedFileReader.shared.data(at: url), data.count <= 40_000_000,
                      let image = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                      width.doubleValue > 0, height.doubleValue > 0, width.doubleValue * height.doubleValue <= 50_000_000,
                      CGImageSourceCreateThumbnailAtIndex(image, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32] as CFDictionary) != nil,
                      let type = CGImageSourceGetType(image), let suffix = UTType(type as String)?.preferredFilenameExtension else {
                    throw ThemeError.message("\(url.lastPathComponent) is not a readable image under 40 MB and 50 megapixels. No wallpapers were added.")
                }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let item = Item(id: "custom:" + hash, file: hash + "." + suffix, name: url.deletingPathExtension().lastPathComponent)
                let destination = directory.appendingPathComponent(item.file)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try data.write(to: destination, options: .atomic)
                    created.append(destination)
                }
                if !entry.added.contains(where: { $0.id == item.id }) { entry.added.append(item) }
                entry.hidden.remove(item.id)
                if !ids.contains(item.id) { ids.append(item.id) }
            }
            // Keep this batch visible at the start of the thumbnail strip.
            entry.added = ids.compactMap { id in entry.added.first { $0.id == id } }
                + entry.added.filter { !ids.contains($0.id) }
            var updated = state
            updated[themeID] = entry
            try save(updated)
            return ids
        } catch {
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    func setHidden(_ hidden: Bool, id: String, themeID: String) throws {
        var updated = state, entry = state[themeID] ?? Entry()
        if hidden { entry.hidden.insert(id) } else { entry.hidden.remove(id) }
        updated[themeID] = entry
        try save(updated)
    }

    func restoreRemoved(themeID: String) throws {
        var updated = state
        updated[themeID]?.hidden.removeAll()
        try save(updated)
    }

    nonisolated static func choices(_ base: [WallpaperChoice], themeID: String, root: URL, snapshot: Snapshot) -> [WallpaperChoice] {
        let entry = snapshot[themeID] ?? Entry()
        let added = entry.added.map { WallpaperChoice(id: $0.id, name: $0.name, url: root.appendingPathComponent("CustomWallpapers").appendingPathComponent($0.file)) }
        return (added + base).filter { !entry.hidden.contains($0.id) }
    }
}
