import Testing
@testable import MigrationKit
@Test func semanticVersionParsesValidInput() throws {
    let version = try SemanticVersion("1.2.3")
    #expect(version.major == 1)
    #expect(version.minor == 2)
    #expect(version.patch == 3)
    #expect(version.description == "1.2.3")
}

@Test func semanticVersionRejectsInvalidInput() {
    do {
        _ = try SemanticVersion("1.0")
        Issue.record("Expected invalid semantic version format.")
    } catch SemanticVersionError.invalidFormat(let value) {
        #expect(value == "1.0")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func runnerAppliesOnlyStepsInsideVersionRange() throws {
    let runner = try MigrationRunner<Int>(steps: [
        try .init(id: "bootstrap", version: "1.0.0") { $0 += 1 },
        try .init(id: "add-index", version: "1.1.0") { $0 += 2 },
        try .init(id: "remove-legacy", version: "2.0.0") { $0 += 3 }
    ])

    let report = try runner.migrate(10, from: "1.0.0", to: "2.0.0")
    let expectedStart = try SemanticVersion("1.0.0")
    let expectedEnd = try SemanticVersion("2.0.0")
    #expect(report.state == 15)
    #expect(report.appliedStepIDs == ["add-index", "remove-legacy"])
    #expect(report.startingVersion == expectedStart)
    #expect(report.finalVersion == expectedEnd)
}

@Test func runnerThrowsForDuplicateStepVersions() {
    do {
        _ = try MigrationRunner<Int>(steps: [
            try .init(version: "1.0.0") { _ in },
            try .init(version: "1.0.0") { _ in }
        ])
        Issue.record("Expected duplicate version error.")
    } catch MigrationRunnerError.duplicateVersion(let version) {
        let expected = try? SemanticVersion("1.0.0")
        #expect(version == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func runnerThrowsForInvalidTargetRange() throws {
    let runner = try MigrationRunner<Int>(steps: [])

    do {
        _ = try runner.migrate(0, from: "2.0.0", to: "1.0.0")
        Issue.record("Expected invalid range error.")
    } catch MigrationRunnerError.invalidRange(let from, let to) {
        let expectedFrom = try? SemanticVersion("2.0.0")
        let expectedTo = try? SemanticVersion("1.0.0")
        #expect(from == expectedFrom)
        #expect(to == expectedTo)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
