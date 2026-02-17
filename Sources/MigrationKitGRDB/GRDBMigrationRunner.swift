import Foundation
import GRDB
import MigrationKit

public struct GRDBMigrationRunner: Sendable {
    public typealias Step = MigrationStep<Database>

    private let registry: MigrationRegistry<Database>
    private let integration: MigrationHostIntegration<any DatabaseWriter, Database>
    private let log: (@Sendable (String) -> Void)?

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
        let applied = try appliedMigrationIdentifiers(in: writer)
        guard let latest = latestAppliedIdentifier(from: applied) else {
            log?("↩️ Rollback skipped: no applied migrations found")
            return
        }
        try rollbackMigration(identifier: latest, in: writer)
    }

    public func rollbackMigrations(in writer: any DatabaseWriter, steps count: Int = 1) throws {
        guard count >= 0 else {
            throw MigrationKitError.rollbackStepCountMustBeNonNegative(count)
        }
        guard count > 0 else { return }

        for _ in 0..<count {
            let applied = try appliedMigrationIdentifiers(in: writer)
            guard latestAppliedIdentifier(from: applied) != nil else { return }
            try rollbackLastMigration(in: writer)
        }
    }

    public func rollbackMigration(identifier: String, in writer: any DatabaseWriter) throws {
        guard let step = registry.steps.first(where: { $0.identifier == identifier }) else {
            throw MigrationKitError.unknownMigrationIdentifier(identifier)
        }
        guard let rollback = step.rollback else {
            throw MigrationKitError.rollbackNotDefined(identifier)
        }

        let applied = try appliedMigrationIdentifiers(in: writer)
        guard applied.contains(identifier) else {
            log?("↩️ Rollback skipped: migration \(identifier) is not applied")
            return
        }

        guard let latest = latestAppliedIdentifier(from: applied) else {
            log?("↩️ Rollback skipped: no applied migrations found")
            return
        }

        guard latest == identifier else {
            throw MigrationKitError.rollbackMustTargetLatestApplied(
                latestApplied: latest,
                requested: identifier
            )
        }

        try writer.write { db in
            try rollback(db)
            if try db.tableExists("grdb_migrations") {
                let columns = try db.columns(in: "grdb_migrations")
                let hasIdentifierColumn = columns.contains { $0.name == "identifier" }
                if hasIdentifierColumn {
                    try db.execute(
                        sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                        arguments: [identifier]
                    )
                }
            }
        }

        try writer.read { db in
            try runIntegrityCheck(in: db)
        }
        try runPostMigrationChecks(in: writer)
        log?("↩️ Rolled back migration \(identifier)")
    }

    public func appliedMigrationIdentifiers(in writer: any DatabaseWriter) throws -> Set<String> {
        try writer.read { db in
            guard try db.tableExists("grdb_migrations") else { return [] }
            return Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
        }
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

    private func latestAppliedIdentifier(from applied: Set<String>) -> String? {
        migrationIdentifiers.reversed().first(where: { applied.contains($0) })
    }
}
