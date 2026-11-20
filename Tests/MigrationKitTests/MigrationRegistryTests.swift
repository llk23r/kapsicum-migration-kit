import XCTest

@testable import MigrationKit

final class MigrationRegistryTests: XCTestCase {
    func testRejectsDuplicateIdentifiers() {
        let steps = [
            MigrationStep<Int>(identifier: "0001_alpha", sourceFile: "A.swift", apply: { _ in }),
            MigrationStep<Int>(identifier: "0001_alpha", sourceFile: "B.swift", apply: { _ in }),
        ]

        XCTAssertThrowsError(
            try MigrationRegistry(steps: steps),
            "Expected duplicate identifiers to be rejected"
        ) { error in
            guard case MigrationKitError.duplicateIdentifiers(let duplicates) = error else {
                return XCTFail("Expected duplicateIdentifiers error, got \(error)")
            }
            XCTAssertEqual(duplicates, ["0001_alpha"])
        }
    }

    func testRejectsOutOfOrderIdentifiersWhenEnforced() {
        let steps = [
            MigrationStep<Int>(identifier: "0002_beta", sourceFile: "B.swift", apply: { _ in }),
            MigrationStep<Int>(identifier: "0001_alpha", sourceFile: "A.swift", apply: { _ in }),
        ]

        XCTAssertThrowsError(
            try MigrationRegistry(steps: steps, enforceLexicographicOrder: true),
            "Expected out-of-order identifiers to be rejected"
        ) { error in
            guard case MigrationKitError.identifiersOutOfOrder(let expected, let actual) = error else {
                return XCTFail("Expected identifiersOutOfOrder error, got \(error)")
            }
            XCTAssertEqual(expected, ["0001_alpha", "0002_beta"])
            XCTAssertEqual(actual, ["0002_beta", "0001_alpha"])
        }
    }

    func testAllowsOutOfOrderIdentifiersWhenOrderEnforcementDisabled() throws {
        let steps = [
            MigrationStep<Int>(identifier: "0002_beta", sourceFile: "B.swift", apply: { _ in }),
            MigrationStep<Int>(identifier: "0001_alpha", sourceFile: "A.swift", apply: { _ in }),
        ]

        let registry = try MigrationRegistry(steps: steps, enforceLexicographicOrder: false)
        XCTAssertEqual(registry.identifiers, ["0002_beta", "0001_alpha"])
    }

    func testReferencesParseAndFormatBothWays() {
        XCTAssertEqual(MigrationReference("0091_x"), MigrationReference(identifier: "0091_x"))
        XCTAssertEqual(MigrationReference("0091_x@1"), MigrationReference(identifier: "0091_x", revision: 1))
        XCTAssertEqual(MigrationReference(identifier: "0091_x", revision: 12).description, "0091_x@12")
        XCTAssertEqual(MigrationReference(identifier: "0091_x").description, "0091_x")
        for malformed in ["", "@1", "0091_x@", "0091_x@0", "0091_x@-1", "0091_x@one"] {
            XCTAssertNil(MigrationReference(malformed), malformed)
        }
        let literal: MigrationReference = "0092_fix_x@3"
        XCTAssertEqual(literal, MigrationReference(identifier: "0092_fix_x", revision: 3))
    }

    func testAcceptsASquashThatNamesItselfAtAnEarlierRevision() throws {
        let registry = try MigrationRegistry(steps: [
            MigrationStep<Int>(
                identifier: "0091_x",
                sourceFile: "X.swift",
                revision: 2,
                supersedes: ["0091_x@1", "0092_fix_x"],
                apply: { _ in }
            )
        ])
        XCTAssertEqual(registry.steps[0].supersedes.map(\.description), ["0091_x@1", "0092_fix_x"])
    }

    func testRejectsSupersessionThatCannotBeTold() {
        let cases: [(steps: [MigrationStep<Int>], reference: String)] = [
            // A superseded migration that is still registered.
            ([step("0001_a"), step("0002_b", supersedes: ["0001_a"])], "0001_a"),
            // Itself, at any revision or at its own.
            ([step("0001_a", supersedes: ["0001_a"])], "0001_a"),
            ([step("0001_a", revision: 2, supersedes: ["0001_a@2"])], "0001_a@2"),
            // Named twice.
            ([step("0001_a", supersedes: ["0000_x"]), step("0002_b", supersedes: ["0000_x@1"])], "0000_x@1"),
            // A literal that is not a reference.
            ([step("0001_a", supersedes: ["0000_x@one"])], "0000_x@one"),
        ]
        for (steps, reference) in cases {
            XCTAssertThrowsError(try MigrationRegistry(steps: steps)) { error in
                guard case MigrationKitError.invalidSupersession(_, let rejected) = error else {
                    return XCTFail("Expected invalidSupersession, got \(error)")
                }
                XCTAssertEqual(rejected, reference)
            }
        }
    }

    private func step(_ identifier: String, revision: Int = 1, supersedes: [MigrationReference] = [])
        -> MigrationStep<Int>
    {
        MigrationStep(
            identifier: identifier, sourceFile: "\(identifier).swift", revision: revision,
            supersedes: supersedes, apply: { _ in })
    }
}
