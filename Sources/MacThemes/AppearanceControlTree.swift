import Foundation

/// A short-lived, in-memory view of controls. Never persisted or logged.
struct AppearanceControlTree<Element> {
    struct Node {
        var element: Element
        var role: String
        var names: [String]
        var parent: Int?
    }
    var nodes: [Node]
    var complete = true

    private func named(_ node: Node, _ name: String) -> Bool {
        node.names.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }
    }

    private func buttonNamed(_ index: Int, _ name: String) -> Bool {
        guard nodes[index].role == "AXButton" else { return false }
        if named(nodes[index], name) { return true }
        // Some native bridges expose a button's visible label only as its
        // static-text child. Keep that fallback inside the button itself.
        return descendants(of: index).contains { nodes[$0].role == "AXStaticText" && named(nodes[$0], name) }
    }

    func themeButton(_ action: String, variant: String) -> Element? {
        guard complete, ["light", "dark"].contains(variant), ["Import", "Copy"].contains(action) else { return nil }
        let qualified = "\(action) \(variant.capitalized) theme"
        let exact = nodes.indices.filter { buttonNamed($0, qualified) }
        if exact.count == 1 { return nodes[exact[0]].element }
        if !exact.isEmpty { return nil }

        let heading = "\(variant.capitalized) theme"
        let otherHeading = variant == "dark" ? "Light theme" : "Dark theme"
        let visible = action == "Copy" ? "Copy theme" : "Import"
        let headingRoles = ["AXHeading", "AXStaticText", "AXGroup"]
        var matches = Set<Int>()
        for index in nodes.indices where headingRoles.contains(nodes[index].role) && named(nodes[index], heading) {
            var ancestor: Int? = index
            // Stop at the nearest common container for the heading and button.
            // Never select a generic Import from the sidebar or another card.
            for _ in 0..<7 {
                guard let container = ancestor else { break }
                let contents = descendants(of: container)
                if contents.contains(where: { headingRoles.contains(nodes[$0].role) && named(nodes[$0], otherHeading) }) { break }
                let candidates = contents.filter { buttonNamed($0, visible) }
                if !candidates.isEmpty {
                    guard candidates.count == 1 else { return nil }
                    matches.insert(candidates[0])
                    break
                }
                ancestor = nodes[container].parent
            }
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        return nodes[match].element
    }

    /// Diagnostics contain only counts of fixed, integration-owned labels.
    /// No window titles, conversation text or arbitrary accessibility values.
    var diagnosticSummary: String {
        let labels = ["Appearance", "Light", "Dark", "System", "Light theme", "Dark theme", "Import", "Copy theme", "Import Light theme", "Import Dark theme"]
        let counts = labels.map { label in "\(label)=\(nodes.filter { named($0, label) }.count)" }
        return "\(nodes.count) controls; " + counts.joined(separator: ", ")
    }

    private func descendants(of root: Int) -> [Int] {
        var included: Set<Int> = [root]
        // Parents precede children in the breadth-first snapshot.
        for index in nodes.indices where index > root {
            if let parent = nodes[index].parent, included.contains(parent) { included.insert(index) }
        }
        return included.sorted()
    }
}
