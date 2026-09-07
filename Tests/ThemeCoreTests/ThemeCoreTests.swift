import Foundation
import Testing
@testable import ThemeCore

@Test func preservesConfigOnRestore() throws {
    for source in ["", "font-size = 14", "font-size = 14\n", "# Comments\n\ncommand = /bin/zsh\n\n"] {
        let result = try ManagedConfig.applying(to: source, includePath: "/Users/test/Library/Application Support/Mac Themes/ghostty.conf")
        #expect(try ManagedConfig.removing(from: result) == source)
        #expect(try ManagedConfig.applying(to: result, includePath: "/Users/test/Library/Application Support/Mac Themes/ghostty.conf") == result)
    }
}

@Test func preservesEditsOutsideManagedBlock() throws {
    let result = try ManagedConfig.applying(to: "font-size = 14\n", includePath: "/theme.conf") + "keybind = ctrl+a=select_all\n"
    #expect(try ManagedConfig.removing(from: result) == "font-size = 14\nkeybind = ctrl+a=select_all\n")
}

@Test func refusesBrokenBlocksAndUnsafePaths() {
    #expect(throws: (any Error).self) { try ManagedConfig.removing(from: ManagedConfig.start) }
    #expect(throws: (any Error).self) { try ManagedConfig.removing(from: ManagedConfig.end + ManagedConfig.start) }
    #expect(throws: (any Error).self) { try ManagedConfig.applying(to: "", includePath: "/tmp/test\ncommand = evil") }
}

@Test func palettesAreValidAndComplete() {
    for theme in Theme.all {
        #expect(theme.palette.count == 16)
        for color in theme.palette + [theme.background, theme.foreground, theme.accent, theme.selection, theme.cursor] {
            #expect(color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil)
        }
        #expect(theme.ghosttyConfig.components(separatedBy: "\n").filter { $0.hasPrefix("palette =") }.count == 16)
        #expect(!theme.ghosttyConfig.contains("command ="))
    }
}

@Test func convertsRGBWithoutLosingPrecision() {
    #expect(ScriptLiteral.rgb("#ff8000") == [65535, 32896, 0])
    #expect(ScriptLiteral.string("a\"b\\c") == "\"a\\\"b\\\\c\"")
}

@Test func corruptedSavedPalettesFailBeforeRenderingOrGeneratingConfiguration() throws {
    let original = try JSONEncoder().encode(Theme.all[0])
    var data = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    data["palette"] = [String]()
    #expect(throws: (any Error).self) { try JSONDecoder().decode(Theme.self, from: JSONSerialization.data(withJSONObject: data)) }
    data["palette"] = Theme.all[0].palette
    data["accent"] = "red; run something"
    #expect(throws: (any Error).self) { try JSONDecoder().decode(Theme.self, from: JSONSerialization.data(withJSONObject: data)) }
    #expect(try JSONDecoder().decode(Theme.self, from: original) == Theme.all[0])
}

@Test func atomicWritePreservesDotfilesSymlinkAndPermissions() throws {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: directory) }
    let target = directory.appendingPathComponent("dotfile")
    let link = directory.appendingPathComponent("config")
    let original = "font-size = 14\ncommand = /bin/zsh\n"
    try original.write(to: target, atomically: true, encoding: .utf8)
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    try files.createSymbolicLink(at: link, withDestinationURL: target)
    try ManagedConfig.write(ManagedConfig.applying(to: original, includePath: "/tmp/theme.conf"), to: link)
    #expect(try files.destinationOfSymbolicLink(atPath: link.path) == target.path)
    #expect((try files.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let contents = try String(contentsOf: link, encoding: .utf8)
    try ManagedConfig.write(ManagedConfig.removing(from: contents), to: link)
    #expect(try String(contentsOf: target, encoding: .utf8) == original)
}

@Test func installedGhosttyAcceptsGeneratedPalettes() throws {
    let executable = URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for theme in Theme.all {
        let config = root.appendingPathComponent("\(theme.id).conf")
        try theme.ghosttyConfig.write(to: config, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["+validate-config", "--config-file=\(config.path)"]
        let output = Pipe()
        process.standardError = output
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(theme.name): \(String(decoding: data, as: UTF8.self))")
    }
}

@Test func bundledPalettesMatchPinnedUpstreamColors() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    #expect(Set(Theme.bundled.map(\.id)).count == 7)
    for theme in Theme.bundled {
        let source = try String(contentsOf: root.appendingPathComponent("Vendor/Omarchy/\(theme.id)/colors.toml"), encoding: .utf8)
        let converted = try ThemePaletteConverter.convert(files: ["colors.toml": source], id: theme.id, name: theme.name)
        #expect(converted.palette.map { $0.lowercased() } == theme.palette.map { $0.lowercased() })
        #expect(converted.background.lowercased() == theme.background.lowercased())
        #expect(converted.foreground.lowercased() == theme.foreground.lowercased())
        #expect(converted.accent.lowercased() == theme.accent.lowercased())
        #expect(converted.selection.lowercased() == theme.selection.lowercased())
        #expect(converted.cursor.lowercased() == theme.cursor.lowercased())
        #expect(!theme.isLight)
    }
}
