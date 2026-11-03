import Foundation

public enum MigrationKitError: LocalizedError, Equatable {
    case duplicateIdentifiers([String])
    case identifiersOutOfOrder(expected: [String], actual: [String])
    case unknownMigrationTarget(String)
    case unknownMigrationIdentifier(String)
    case rollbackNotDefined(String)
    case rollbackStepCountMustBeNonNegative(Int)
    case rollbackMustTargetLatestApplied(latestApplied: String, requested: String)
    case rollbackBlockedByUnknownMigrations([String])
    case rollbackPlanChanged(expected: [String], actual: [String])

    public var errorDescription: String? {
        switch self {
        case .duplicateIdentifiers(let duplicates):
            return "Duplicate migration identifiers found: \(duplicates.joined(separator: ", "))"
        case .identifiersOutOfOrder(let expected, let actual):
            return """
                Migration identifiers must be append-only and lexicographically ordered.
                Expected order: \(expected.joined(separator: ", "))
                Actual order: \(actual.joined(separator: ", "))
                """
        case .unknownMigrationTarget(let target):
            return "Unknown migration target '\(target)'"
        case .unknownMigrationIdentifier(let identifier):
            return "Unknown migration identifier '\(identifier)'"
        case .rollbackNotDefined(let identifier):
            return "Rollback is not defined for migration '\(identifier)'"
        case .rollbackStepCountMustBeNonNegative(let count):
            return "Rollback step count must be >= 0 (received \(count))"
        case .rollbackMustTargetLatestApplied(let latestApplied, let requested):
            return
                "Can only rollback the latest applied migration. Latest is '\(latestApplied)', requested '\(requested)'."
        case .rollbackBlockedByUnknownMigrations(let identifiers):
            return """
                The database has migrations this build does not know, applied after the ones to roll back: \
                \(identifiers.joined(separator: ", ")). Roll those back first with the build that applied them.
                """
        case .rollbackPlanChanged(let expected, let actual):
            return """
                The database changed since the rollback was measured: it would now reverse \
                [\(actual.joined(separator: ", "))], not [\(expected.joined(separator: ", "))]. Nothing was rolled back.
                """
        }
    }
}
