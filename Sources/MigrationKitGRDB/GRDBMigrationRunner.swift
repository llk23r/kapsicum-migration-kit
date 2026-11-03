import Foundation
import GRDB
import MigrationKit

public struct GRDBMigrationRunner: Sendable {
    public typealias Step = MigrationStep<Database>

    private let registry: MigrationRegistry<Database>
    private let integration: MigrationHostIntegration<any DatabaseWriter, Database>
    private let log: (@Sendable (String) -> Void)?
    /// Whether the registry enforces lexicographic order: the only promise that a later build's
    /// identifiers sort after this one's, which places an unknown applied identifier. A registry
    /// that merely happens to be sorted promises nothing about the next build's.
    private let identifiersSortInOrder: Bool

    public init(
        steps: [Step],
        enforceLexicographicOrder: Bool = true,
        integration: MigrationHostIntegration<any DatabaseWriter, Database> = .init(),
        log: (@Sendable (String) -> Void)? = nil
    ) throws {
        self.registry = try MigrationRegistry(
            steps: steps,
            enforceLexicographicOrder: enforceLexicographicOrder
        )
        self.integration = integration
        self.log = log
        self.identifiersSortInOrder = enforceLexicographicOrder
    }

    public var migrationIdentifiers: [String] {
        registry.identifiers
    }

    public var migrationManifest: [(identifier: String, sourceFile: String)] {
        registry.manifest
    }

    public var rollbackCapableMigrationIdentifiers: [String] {
        registry.rollbackCapableIdentifiers
    }

    public func migrate(in writer: any DatabaseWriter) throws {
        try runBootstrapSchemaIfConfigured(in: writer)
        let migrator = buildMigrator()
        try migrator.migrate(writer)
        try runPostMigrationChecks(in: writer)
        log?("✅ Migration complete for \(registry.steps.count) registered migrations.")
    }

    public func migrate(in writer: any DatabaseWriter, upTo targetIdentifier: String) throws {
        guard migrationIdentifiers.contains(targetIdentifier) else {
            throw MigrationKitError.unknownMigrationTarget(targetIdentifier)
        }
        try runBootstrapSchemaIfConfigured(in: writer)

        let migrator = buildMigrator()
        try migrator.migrate(writer, upTo: targetIdentifier)

        if migrationIdentifiers.last == targetIdentifier {
            try runPostMigrationChecks(in: writer)
        } else {
            try writer.read { db in
                try runIntegrityCheck(in: db)
            }
        }

        log?("✅ Migration complete up to \(targetIdentifier)")
    }

    public func migrationStatus(in writer: any DatabaseWriter) throws -> [MigrationStatus] {
        let appliedIdentifiers = try appliedMigrationIdentifiers(in: writer)
        return registry.steps.map { step in
            MigrationStatus(
                identifier: step.identifier,
                sourceFile: step.sourceFile,
                state: appliedIdentifiers.contains(step.identifier) ? .up : .down
            )
        }
    }

    public func pendingMigrationIdentifiers(in writer: any DatabaseWriter) throws -> [String] {
        try migrationStatus(in: writer)
            .filter { $0.state == .down }
            .map(\.identifier)
    }

    public func hasPendingMigrations(in writer: any DatabaseWriter) throws -> Bool {
        try !pendingMigrationIdentifiers(in: writer).isEmpty
    }

    public func rollbackLastMigration(in writer: any DatabaseWriter) throws {
        try rollback(.steps(1), in: writer)
    }

    public func rollbackMigrations(in writer: any DatabaseWriter, steps count: Int = 1) throws {
        try rollback(.steps(count), in: writer)
    }

    public func rollbackMigration(identifier: String, in writer: any DatabaseWriter) throws {
        guard let step = registry.steps.first(where: { $0.identifier == identifier }) else {
            throw MigrationKitError.unknownMigrationIdentifier(identifier)
        }
        guard step.rollback != nil else {
            throw MigrationKitError.rollbackNotDefined(identifier)
        }
        try reverse(in: writer) { applied in
            guard applied.contains(identifier) else { return [] }
            let latest = registry.identifiers.last(where: applied.contains) ?? identifier
            guard latest == identifier else {
                throw MigrationKitError.rollbackMustTargetLatestApplied(latestApplied: latest, requested: identifier)
            }
            return try planned([step], applied: applied)
        }
    }

    /// Reverses `target`'s migrations in one transaction: every step's rollback runs and leaves
    /// `grdb_migrations`, then the host's `didRollback` runs, or nothing changes at all.
    ///
    /// The steps are chosen and checked inside that transaction, before any of them runs. A step
    /// with no rollback, or a migration this build does not know applied after the ones to
    /// reverse, refuses the whole rollback. So does a choice other than `expected`, the
    /// identifiers a `rollbackReport` showed, when another writer reversed or applied migrations
    /// since. Returns the reversed identifiers, newest first.
    @discardableResult
    public func rollback(
        _ target: RollbackTarget,
        in writer: any DatabaseWriter,
        expecting expected: [String]? = nil
    ) throws -> [String] {
        try reverse(in: writer) { applied in
            let steps = try plan(target, applied: applied)
            if let expected, steps.map(\.identifier) != expected {
                throw MigrationKitError.rollbackPlanChanged(expected: expected, actual: steps.map(\.identifier))
            }
            return steps
        }
    }

    /// Measures what `rollback(target, in:)` would take away, and changes nothing.
    ///
    /// The steps run inside a savepoint that is then undone, and the tables and columns they
    /// removed are counted as they stand. A rollback closure must therefore only change the
    /// database, which is already what a failed rollback assumes: SQLite undoes it.
    public func rollbackReport(_ target: RollbackTarget, in writer: any DatabaseWriter) throws -> RollbackReport {
        try writer.writeWithoutTransaction { db in
            // Every exit undoes schema changes GRDB's schema cache saw as they ran, and GRDB
            // never clears that cache on a ROLLBACK.
            defer { db.clearSchemaCache() }
            var report = RollbackReport(identifiers: [], removedTables: [], removedColumns: [])
            try db.inTransaction {
                let steps = try plan(target, applied: try appliedIdentifiers(in: db))
                guard !steps.isEmpty else { return .rollback }
                let before = try SchemaInventory(db)
                var after = before
                try db.inSavepoint {
                    for step in steps { try step.rollback(db) }
                    after = try SchemaInventory(db)
                    return .rollback
                }
                report = try before.removals(
                    leaving: after,
                    identifiers: steps.map(\.identifier),
                    countedIn: db
                )
                return .rollback
            }
            return report
        }
    }

    public func appliedMigrationIdentifiers(in writer: any DatabaseWriter) throws -> Set<String> {
        try writer.read { db in try appliedIdentifiers(in: db) }
    }

    public func runPostMigrationChecks(in writer: any DatabaseWriter) throws {
        if let verifyPostMigration = integration.verifyPostMigration {
            try verifyPostMigration(writer)
            return
        }

        try writer.read { db in
            try runIntegrityCheck(in: db)
        }
    }

    /// One step chosen for reversal, with the rollback it was checked to have.
    private struct PlannedRollback {
        let identifier: String
        let sourceFile: String
        let rollback: @Sendable (Database) throws -> Void
    }

    private func plan(_ target: RollbackTarget, applied: Set<String>) throws -> [PlannedRollback] {
        let appliedSteps = registry.steps.filter { applied.contains($0.identifier) }
        let reversed: [Step]
        switch target {
        case .steps(let count):
            guard count >= 0 else {
                throw MigrationKitError.rollbackStepCountMustBeNonNegative(count)
            }
            reversed = appliedSteps.suffix(count).reversed()
        case .to(let identifier):
            guard let targetIndex = registry.identifiers.firstIndex(of: identifier) else {
                throw MigrationKitError.unknownMigrationTarget(identifier)
            }
            let later = Set(registry.identifiers[(targetIndex + 1)...])
            reversed = appliedSteps.filter { later.contains($0.identifier) }.reversed()
        }
        return try planned(reversed, applied: applied)
    }

    /// `steps`, newest first, once each has a rollback and no unknown migration was applied after
    /// the oldest of them. Unknown identifiers that sort before it are another branch's history,
    /// which these steps cannot depend on; without sorted identifiers, any unknown one refuses.
    private func planned(_ steps: [Step], applied: Set<String>) throws -> [PlannedRollback] {
        guard let oldest = steps.last else { return [] }
        let newer = applied.subtracting(registry.identifiers)
            .filter { !identifiersSortInOrder || $0 > oldest.identifier }
            .sorted()
        guard newer.isEmpty else {
            throw MigrationKitError.rollbackBlockedByUnknownMigrations(newer)
        }
        return try steps.map { step in
            guard let rollback = step.rollback else {
                throw MigrationKitError.rollbackNotDefined(step.identifier)
            }
            return PlannedRollback(identifier: step.identifier, sourceFile: step.sourceFile, rollback: rollback)
        }
    }

    @discardableResult
    private func reverse(
        in writer: any DatabaseWriter,
        choosing choose: (Set<String>) throws -> [PlannedRollback]
    ) throws -> [String] {
        let reversed: [String] = try writer.writeWithoutTransaction { db in
            var reversed: [String] = []
            do {
                try db.inTransaction {
                    let steps = try choose(try appliedIdentifiers(in: db))
                    guard !steps.isEmpty else { return .rollback }
                    for step in steps {
                        log?("↩️ Rolling back migration \(step.identifier) from \(step.sourceFile)")
                        try step.rollback(db)
                        try db.execute(
                            sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                            arguments: [step.identifier]
                        )
                    }
                    try integration.didRollback?(db)
                    reversed = steps.map(\.identifier)
                    return .commit
                }
            } catch {
                // SQLite undid the steps' schema changes; GRDB's schema cache only learns of DDL as
                // it runs, never of a ROLLBACK, so it would still describe the undone schema.
                db.clearSchemaCache()
                throw error
            }
            return reversed
        }
        guard !reversed.isEmpty else {
            log?("↩️ Rollback skipped: no applied migration to reverse")
            return []
        }
        try runPostMigrationChecks(in: writer)
        log?("↩️ Rolled back \(reversed.joined(separator: ", "))")
        return reversed
    }

    private func appliedIdentifiers(in db: Database) throws -> Set<String> {
        guard try db.tableExists("grdb_migrations") else { return [] }
        return Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
    }

    private func buildMigrator() -> GRDB.DatabaseMigrator {
        var migrator = GRDB.DatabaseMigrator()

        for step in registry.steps {
            migrator.registerMigration(step.identifier) { db in
                log?("🧱 Applying migration \(step.identifier) from \(step.sourceFile)")
                try step.apply(db)
            }
        }

        return migrator
    }

    private func runBootstrapSchemaIfConfigured(in writer: any DatabaseWriter) throws {
        guard let bootstrapSchema = integration.bootstrapSchema else {
            return
        }

        try writer.write { db in
            let didCreateBaseSchema = try bootstrapSchema(db)
            if didCreateBaseSchema {
                log?("🧱 Base schema created before migrations")
            }
        }
    }

    private func runIntegrityCheck(in db: Database) throws {
        if let verifyIntegrity = integration.verifyIntegrity {
            try verifyIntegrity(db)
            return
        }
        try GRDBMigrationVerifier.verifyIntegrity(in: db)
    }
}
