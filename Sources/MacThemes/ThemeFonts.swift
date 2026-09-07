import AppKit
import CoreText
import CryptoKit
import ThemeCore

/// One family per choice; only Regular and Bold are bundled for Nerd Fonts.
struct ThemeFont: Identifiable, Sendable {
    let id: String
    let name: String
    let family: String
    let directory: String?
    let filePrefix: String

    static let all: [ThemeFont] = [
        .init(id: "jetbrains", name: "JetBrains Mono", family: "JetBrainsMono Nerd Font Mono", directory: "JetBrainsMono/Ligatures", filePrefix: "JetBrainsMono"),
        .init(id: "fira", name: "Fira Code", family: "FiraCode Nerd Font Mono", directory: "FiraCode", filePrefix: "FiraCode"),
        .init(id: "hack", name: "Hack", family: "Hack Nerd Font Mono", directory: "Hack", filePrefix: "Hack"),
        .init(id: "iosevka", name: "Iosevka", family: "Iosevka Nerd Font Mono", directory: "Iosevka", filePrefix: "Iosevka"),
        .init(id: "cascadia", name: "Cascadia Code", family: "CaskaydiaCove Nerd Font Mono", directory: "CascadiaCode", filePrefix: "CaskaydiaCove"),
        .init(id: "meslo", name: "Meslo LG S", family: "MesloLGS Nerd Font Mono", directory: "Meslo/S", filePrefix: "MesloLGS"),
        .init(id: "plex", name: "IBM Plex Mono", family: "BlexMono Nerd Font Mono", directory: "IBMPlexMono", filePrefix: "BlexMono"),
        .init(id: "source", name: "Source Code Pro", family: "SauceCodePro Nerd Font Mono", directory: "SourceCodePro", filePrefix: "SauceCodePro"),
        .init(id: "menlo", name: "Menlo", family: "Menlo", directory: nil, filePrefix: ""),
        .init(id: "monaco", name: "Monaco", family: "Monaco", directory: nil, filePrefix: "")
    ]

    func files(in resources: URL) -> [URL] {
        guard let directory else { return [] }
        return ["Regular", "Bold"].map {
            resources.appendingPathComponent(directory).appendingPathComponent("\(filePrefix)NerdFontMono-\($0).ttf")
        }
    }

    static var resources: URL? { Bundle.main.resourceURL?.appendingPathComponent("NerdFonts") }

    func registerPreview() {
        guard let resources = Self.resources else { return }
        for url in files(in: resources) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Install or upgrade only this family's tracked faces; preserve unrelated font files.
    func install(resources: URL? = ThemeFont.resources,
                 destination: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts/MacThemes")) throws {
        guard directory != nil else { return }
        guard let resources else { throw ThemeError.message("The bundled font files are missing. Rebuild Mac Themes.") }
        let files = FileManager.default
        let sources = self.files(in: resources)
        let journalURL = destination.appendingPathComponent(".mac-themes-fonts.json")
        struct Ownership: Codable { var current: String; var previous: String? }
        var owned = try BoundedFileReader.shared.data(at: journalURL).map {
            try JSONDecoder().decode([String: Ownership].self, from: $0)
        } ?? [:]
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        var writes: [(URL, Data)] = []
        for source in sources {
            guard let data = try BoundedFileReader.shared.data(at: source) else {
                throw ThemeError.message("Missing font: \(source.lastPathComponent)")
            }
            let name = source.lastPathComponent, desired = digest(data)
            let target = destination.appendingPathComponent(name)
            let current = try BoundedFileReader.shared.data(at: target).map(digest)
            if let current, current != desired,
               current != owned[name]?.current && current != owned[name]?.previous {
                throw ThemeError.message("An independently installed or modified \(self.name) font was preserved.")
            }
            // An identical untracked file is usable, but does not become ours to overwrite.
            if current == desired { continue }
            owned[name] = Ownership(current: desired, previous: current)
            writes.append((target, data))
        }
        guard !writes.isEmpty else { return }
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        // Journal both versions before replacing either face; interrupted updates are retryable.
        try JSONEncoder().encode(owned).write(to: journalURL, options: .atomic)
        for (target, data) in writes { try data.write(to: target, options: .atomic) }
    }
}
