import Foundation
import Testing
@testable import MacThemes
import ThemeCore

@Test @MainActor func cliToolsApplySwitchAndRestoreWithoutLiveProcesses() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-tools-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), serviceRoot = root.appendingPathComponent("state")
    let samples: [(String, String)] = [
        (".pi/agent/settings.json", "{\n  // Keep preferred model\n  \"model\": \"fixture-model\", \"theme\": \"dark\", \"skills\": [\"keep\"]\n}\n"),
        (".claude/settings.json", "{\"theme\":\"light\",\"permissions\":{\"defaultMode\":\"default\"},\"hooks\":{}}\n"),
        (".hermes/config.yaml", "model: fixture-model\ndisplay:\n  skin: default # prior choice\n  show_cost: true\n"),
        (".hermes/profiles/work/config.yaml", "model: work-model\ndisplay:\n  skin: slate\n"),
        (".hermes/active_profile", "work\n"),
        (".tmux.conf", "set -g mouse on\n# keep user commands\n")
    ]
    for (path, content) in samples {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
    let integration = try OmarchyToolsIntegration(root: serviceRoot, home: home, live: false)
    #expect(!integration.hasBackups)
    #expect(!FileManager.default.fileExists(atPath: serviceRoot.path))
    for tool in OmarchyTool.allCases {
        _ = try integration.apply(Theme.all[0], to: tool)
        _ = try integration.apply(Theme.all[2], to: tool)
    }
    #expect(integration.hasBackups)
    let pi = try String(contentsOf: home.appendingPathComponent(".pi/agent/settings.json"), encoding: .utf8)
    #expect(pi.contains("Keep preferred model"))
    #expect(pi.contains("fixture-model"))
    #expect(try PaletteJSON.raw(pi, path: ["theme"]) == "\"mac-themes\"")
    let claude = try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8)
    #expect(try PaletteJSON.raw(claude, path: ["permissions", "defaultMode"]) == "\"default\"")
    #expect(try String(contentsOf: home.appendingPathComponent(".hermes/config.yaml"), encoding: .utf8) == samples[2].1)
    #expect(try String(contentsOf: home.appendingPathComponent(".hermes/profiles/work/config.yaml"), encoding: .utf8).contains("skin: \"mac-themes\""))
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".hermes/skins/mac-themes.yaml").path))
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".hermes/profiles/work/skins/mac-themes.yaml").path))
    let restarted = try OmarchyToolsIntegration(root: serviceRoot, home: home, live: false)
    for tool in OmarchyTool.allCases { _ = try restarted.restore(tool) }
    for (path, content) in samples { #expect(try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8) == content) }
    #expect(!restarted.hasBackups)
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".pi/agent/themes/mac-themes.json").path))
}

@Test @MainActor func cliThemeRestorePreservesUnrelatedEditsAndRefusesConflicts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-tools-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), integration = try OmarchyToolsIntegration(root: root.appendingPathComponent("state"), home: home, live: false)
    _ = try integration.apply(Theme.all[0], to: .pi)
    let settings = home.appendingPathComponent(".pi/agent/settings.json")
    var source = try String(contentsOf: settings, encoding: .utf8)
    source = try PaletteJSON.setting(source, path: ["model"], raw: "\"user-edit\"")
    try source.write(to: settings, atomically: true, encoding: .utf8)
    _ = try integration.restore(.pi)
    let restored = try String(contentsOf: settings, encoding: .utf8)
    #expect(try PaletteJSON.raw(restored, path: ["theme"]) == nil)
    #expect(try PaletteJSON.raw(restored, path: ["model"]) == "\"user-edit\"")
    _ = try integration.apply(Theme.all[0], to: .claude)
    let claude = home.appendingPathComponent(".claude/settings.json")
    let changed = try PaletteJSON.setting(String(contentsOf: claude, encoding: .utf8), path: ["theme"], raw: "\"user-choice\"")
    try changed.write(to: claude, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try integration.restore(.claude) }
    #expect(integration.hasBackups)
    #expect(try String(contentsOf: claude, encoding: .utf8) == changed)
}

@Test func hermesSkinScalarEditingPreservesOtherYAMLAndRejectsAmbiguity() throws {
    let original = "model: safe\ndisplay:\n    skin: slate # selected\n    bell_on_complete: true\nother: preserved\n"
    let value = try ToolSkinYAML.raw(original)
    let changed = try ToolSkinYAML.setting(original, raw: " \"mac-themes\"")
    #expect(changed.contains("bell_on_complete: true"))
    #expect(try ToolSkinYAML.setting(changed, raw: value) == original)
    #expect(try ToolSkinYAML.setting("model: safe", raw: " mac-themes") == "model: safe\ndisplay:\n  skin: mac-themes\n")
    #expect(try ToolSkinYAML.setting("display:\n  skin : default\n", raw: " mac-themes") == "display:\n  skin : mac-themes\n")
    for invalid in ["display: {skin: default}\n", "display:\n  skin: default\n  skin: slate\n", "display: &settings\n  skin: default\n", "display:\n  skin: |\n    multiline\n", "\"display\":\n  skin: default\n", "display:\n  'skin': default\n", "'display' :\n  skin: default\n", "display:\n  'skin' : default\n"] {
        #expect(throws: (any Error).self) { try ToolSkinYAML.setting(invalid, raw: " mac-themes") }
    }
}

@Test func generatedCLIPalettesAreCompleteColorData() throws {
    let piRequired = "accent border borderAccent borderMuted success error warning muted dim text thinkingText selectedBg userMessageBg userMessageText customMessageBg customMessageText customMessageLabel toolPendingBg toolSuccessBg toolErrorBg toolTitle toolOutput mdHeading mdLink mdLinkUrl mdCode mdCodeBlock mdCodeBlockBorder mdQuote mdQuoteBorder mdHr mdListBullet toolDiffAdded toolDiffRemoved toolDiffContext syntaxComment syntaxKeyword syntaxFunction syntaxVariable syntaxString syntaxNumber syntaxType syntaxOperator syntaxPunctuation thinkingOff thinkingMinimal thinkingLow thinkingMedium thinkingHigh thinkingXhigh bashMode".split(separator: " ").map(String.init)
    for theme in Theme.all {
        let pi = try #require(JSONSerialization.jsonObject(with: Data(OmarchyToolPalette.pi(theme).utf8)) as? [String: Any])
        let colors = try #require(pi["colors"] as? [String: String])
        #expect(Set(piRequired).isSubset(of: Set(colors.keys)))
        #expect(colors.values.allSatisfy { $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil })
        let claude = try #require(JSONSerialization.jsonObject(with: Data(OmarchyToolPalette.claude(theme).utf8)) as? [String: Any])
        #expect(claude["base"] as? String == (theme.isLight ? "light" : "dark"))
        #expect((claude["overrides"] as? [String: String])?["text"] == theme.foreground)
        let hermes = OmarchyToolPalette.hermes(theme)
        #expect(hermes.hasPrefix("name: mac-themes\n"))
        #expect(!hermes.contains("branding:"))
        #expect(!OmarchyToolPalette.tmux(theme).contains("run-shell"))
        #expect(OmarchyToolPalette.tmuxOptions(theme)["cursor-colour"] == theme.cursor)
    }
}

@MainActor private final class TmuxFixture {
    var options: [String: String] = {
        var values = Dictionary(uniqueKeysWithValues: OmarchyToolPalette.tmuxOptions(Theme.all[0]).keys.map { ($0, "default") })
        values["cursor-colour"] = "none"
        return values
    }()
    var environment = ["global": "COLORFGBG=8;0", "$0": "COLORFGBG=7;0"]
    var sourcedOnlyOwnedFile = true
    var sessions = ["$0"]
    func run(_ command: URL, _ args: [String]) throws -> String {
        switch args[0] {
        case "display-message": return "4242"
        case "show-options": return options[args.last!]!
        case "list-sessions": return sessions.joined(separator: "\n")
        case "list-clients", "refresh-client": return ""
        case "has-session":
            guard sessions.contains(args.last!) else { throw ThemeError.message("Fixture session closed") }; return ""
        case "show-environment": return environment[args.contains("-g") ? "global" : args[2]] ?? "<absent>"
        case "set-environment":
            let scope = args.contains("-g") ? "global" : args[2]
            guard scope == "global" || sessions.contains(scope) else { throw ThemeError.message("Fixture session closed") }
            if args.contains("-u") { environment[scope] = nil }
            else { environment[scope] = "COLORFGBG=" + args.last! }
            return ""
        case "set-option":
            if args[1] == "-gu" { options[args[2]] = "none"; return "" }
            if args[2] == "cursor-colour" && args[3] == "none" { throw ThemeError.message("tmux rejects none as an explicit cursor color") }
            options[args[2]] = args[3]; return ""
        case "source-file":
            sourcedOnlyOwnedFile = sourcedOnlyOwnedFile && URL(fileURLWithPath: args[1]).lastPathComponent == "tmux-theme.conf"
            let text = try String(contentsOfFile: args[1], encoding: .utf8)
            for line in text.split(separator: "\n") {
                let words = line.split(separator: " ", maxSplits: 3).map(String.init)
                if words.count == 4, words[0] == "set-option" { options[words[2]] = words[3].trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
                if words.count == 4, words[0] == "set-environment" { environment["global"] = "COLORFGBG=" + words[3].trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            }
            return ""
        default: throw ThemeError.message("Unexpected fixture command \(args[0])")
        }
    }
}

@Test @MainActor func tmuxLiveCommandFixtureCapturesAndRestoresWithoutUserServer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-tools-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), executable = home.appendingPathComponent(".local/bin/tmux")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "fixture never executed".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let fixture = TmuxFixture(), oldOptions = fixture.options, oldEnvironment = fixture.environment
    let integration = try OmarchyToolsIntegration(root: root.appendingPathComponent("state"), home: home, live: true)
    integration.commandRunner = fixture.run
    _ = try integration.apply(Theme.all[0], to: .tmux)
    #expect(fixture.options["window-style"] == "fg=\(Theme.all[0].foreground),bg=\(Theme.all[0].background)")
    _ = try integration.apply(Theme.all[2], to: .tmux)
    #expect(fixture.environment["$0"] == "COLORFGBG=0;15")
    _ = try integration.restore(.tmux)
    #expect(fixture.options == oldOptions)
    #expect(fixture.environment == oldEnvironment)
    #expect(fixture.sourcedOnlyOwnedFile)
    #expect(!integration.hasBackups)
}

@Test @MainActor func cliRestorePreservesEditsMadeBetweenThemeSwitches() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-between-switches-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), integration = try OmarchyToolsIntegration(root: root.appendingPathComponent("state"), home: home, live: false)
    let hermes = home.appendingPathComponent(".hermes/config.yaml")
    try FileManager.default.createDirectory(at: hermes.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "model: original\ndisplay:\n  skin: default\n".write(to: hermes, atomically: true, encoding: .utf8)
    for tool in OmarchyTool.allCases { _ = try integration.apply(Theme.all[0], to: tool) }
    for path in [".pi/agent/settings.json", ".claude/settings.json"] {
        let url = home.appendingPathComponent(path)
        let updated = try PaletteJSON.setting(String(contentsOf: url, encoding: .utf8), path: ["model"], raw: "\"later-user-edit\"")
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }
    let changedHermes = try String(contentsOf: hermes, encoding: .utf8).replacingOccurrences(of: "model: original", with: "model: later-user-edit")
    try changedHermes.write(to: hermes, atomically: true, encoding: .utf8)
    let tmux = home.appendingPathComponent(".tmux.conf")
    try (String(contentsOf: tmux, encoding: .utf8) + "set -g mouse on\n").write(to: tmux, atomically: true, encoding: .utf8)
    for tool in OmarchyTool.allCases { _ = try integration.apply(Theme.all[2], to: tool); _ = try integration.restore(tool) }
    for path in [".pi/agent/settings.json", ".claude/settings.json"] {
        let current = try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
        #expect(try PaletteJSON.raw(current, path: ["model"]) == "\"later-user-edit\"")
        #expect(try PaletteJSON.raw(current, path: ["theme"]) == nil)
    }
    #expect(try String(contentsOf: hermes, encoding: .utf8).contains("model: later-user-edit"))
    #expect(try String(contentsOf: tmux, encoding: .utf8) == "set -g mouse on\n")
}

@Test @MainActor func tmuxReapplyIgnoresSessionsThatClosedAfterFirstTheme() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmux-closed-fixture-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), command = home.appendingPathComponent(".local/bin/tmux")
    try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "fixture never executed".write(to: command, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
    let fixture = TmuxFixture(), integration = try OmarchyToolsIntegration(root: root.appendingPathComponent("state"), home: home, live: true)
    integration.commandRunner = fixture.run
    _ = try integration.apply(Theme.all[0], to: .tmux)
    fixture.sessions = ["$1"]
    fixture.environment["$0"] = nil
    fixture.environment["$1"] = "COLORFGBG=6;0"
    _ = try integration.apply(Theme.all[2], to: .tmux)
    #expect(fixture.environment["$0"] == nil)
    #expect(fixture.environment["$1"] == "COLORFGBG=0;15")
    _ = try integration.restore(.tmux)
    #expect(fixture.environment["$1"] == "COLORFGBG=6;0")
}
