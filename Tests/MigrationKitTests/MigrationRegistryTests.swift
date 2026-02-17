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
}
