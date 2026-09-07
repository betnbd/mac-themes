import Testing
@testable import MacThemes

private typealias Tree = AppearanceControlTree<String>

private func cards() -> Tree {
    Tree(nodes: [
        .init(element: "window", role: "AXWindow", names: [], parent: nil),
        .init(element: "sidebar-import", role: "AXButton", names: ["Import"], parent: 0),
        .init(element: "light-card", role: "AXGroup", names: [], parent: 0),
        .init(element: "dark-card", role: "AXGroup", names: [], parent: 0),
        .init(element: "light-heading", role: "AXHeading", names: ["Light theme"], parent: 2),
        .init(element: "light-actions", role: "AXGroup", names: [], parent: 2),
        .init(element: "dark-heading", role: "AXHeading", names: ["Dark theme"], parent: 3),
        .init(element: "dark-actions", role: "AXGroup", names: [], parent: 3),
        .init(element: "light-import", role: "AXButton", names: ["Import"], parent: 5),
        .init(element: "light-copy", role: "AXButton", names: ["Copy theme"], parent: 5),
        .init(element: "dark-import", role: "AXButton", names: ["Import"], parent: 7),
        .init(element: "dark-copy", role: "AXButton", names: ["Copy theme"], parent: 7)
    ])
}

@Test func appearanceVisibleLabelsResolveWithinTheirOwnCards() {
    let tree = cards()
    #expect(tree.themeButton("Import", variant: "dark") == "dark-import")
    #expect(tree.themeButton("Copy", variant: "dark") == "dark-copy")
    #expect(tree.themeButton("Import", variant: "light") == "light-import")
    #expect(tree.themeButton("Copy", variant: "light") == "light-copy")
}

@Test func appearanceQualifiedLabelsRemainSupported() {
    var tree = cards()
    tree.nodes[10].names = ["Import Dark theme"]
    tree.nodes[11].names = ["Copy Dark theme"]
    #expect(tree.themeButton("Import", variant: "dark") == "dark-import")
    #expect(tree.themeButton("Copy", variant: "dark") == "dark-copy")
}

@Test func appearanceButtonMayExposeItsLabelAsAStaticTextChild() {
    var tree = cards()
    tree.nodes[10].names = []
    tree.nodes.append(.init(element: "import-label", role: "AXStaticText", names: ["Import"], parent: 10))
    #expect(tree.themeButton("Import", variant: "dark") == "dark-import")
}

@Test func appearanceMustNotBorrowAnotherVariantsImporter() {
    var tree = cards()
    tree.nodes[10].names = []
    #expect(tree.themeButton("Import", variant: "dark") == nil)
    #expect(tree.themeButton("Import", variant: "light") == "light-import")
    tree.nodes[10].names = ["Import"]
    // Flatten both cards into one container: visual order alone is insufficient.
    tree.nodes[4].parent = 0
    tree.nodes[6].parent = 0
    #expect(tree.themeButton("Import", variant: "dark") == nil)
}

@Test func appearanceRejectsAmbiguousAndIncompleteControlTrees() {
    var tree = cards()
    tree.nodes.append(.init(element: "second-import", role: "AXButton", names: ["Import"], parent: 7))
    #expect(tree.themeButton("Import", variant: "dark") == nil)
    tree = cards()
    tree.complete = false
    #expect(tree.themeButton("Import", variant: "light") == nil)
}

@Test func appearanceStaticHeadingAndNamedSectionBothWork() {
    var tree = cards()
    tree.nodes[6].role = "AXStaticText"
    tree.nodes[6].names = ["  Dark theme\n"]
    tree.nodes[3].names = ["Dark theme"]
    #expect(tree.themeButton("Copy", variant: "dark") == "dark-copy")
}

@Test func appearanceDoesNotTreatUnrelatedImportTextAsAButton() {
    var tree = cards()
    tree.nodes[10].role = "AXStaticText"
    #expect(tree.themeButton("Import", variant: "dark") == nil)
    #expect(tree.themeButton("Delete", variant: "dark") == nil)
    #expect(tree.themeButton("Import", variant: "system") == nil)
}

@Test func appearanceDiagnosticsIncludeOnlyKnownControlCounts() {
    var tree = cards()
    tree.nodes.append(.init(element: "private", role: "AXStaticText", names: ["private conversation text"], parent: 0))
    #expect(tree.diagnosticSummary.contains("Dark theme=1"))
    #expect(tree.diagnosticSummary.contains("Import=3"))
    #expect(!tree.diagnosticSummary.contains("private"))
}
