public struct MigrationRegistry<Database> {
    public let steps: [MigrationStep<Database>]

    public init(
        steps: [MigrationStep<Database>],
        enforceLexicographicOrder: Bool = true
    ) throws {
        let identifiers = steps.map(\.identifier)
        let duplicates = Dictionary(grouping: identifiers, by: { $0 })
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()
        if !duplicates.isEmpty {
            throw MigrationKitError.duplicateIdentifiers(duplicates)
        }

        if enforceLexicographicOrder {
            let sorted = identifiers.sorted()
            if sorted != identifiers {
                throw MigrationKitError.identifiersOutOfOrder(expected: sorted, actual: identifiers)
            }
        }

        self.steps = steps
    }

    public var identifiers: [String] {
        steps.map(\.identifier)
    }

    public var manifest: [(identifier: String, sourceFile: String)] {
        steps.map { ($0.identifier, $0.sourceFile) }
    }

    public var rollbackCapableIdentifiers: [String] {
        steps.compactMap { step in
            step.rollback == nil ? nil : step.identifier
        }
    }
}
