import Foundation
import GRDB
import MigrationKit

public struct GRDBMigrationRunner: Sendable {
    public typealias Step = MigrationStep<Database>

    /// The table the runner keeps its migration ledger in, next to `grdb_migrations`.
    public static let ledgerTableName = MigrationLedgerStore.table

    private let registry: MigrationRegistry<Database>
    private let integration: MigrationHostIntegration<any DatabaseWriter, Database>
    /// Recorded with every ledger row this runner writes.
    private let provenance: MigrationProvenance
    private let log: (@Sendable (String) -> Void)?
    /// Whether the registry enforces lexicographic order: the only promise that a later build's
    /// identifiers sort after this one's, which places an unknown applied identifier. A registry
    /// that merely happens to be sorted promises nothing about the next build's.
    private let identifiersSortInOrder: Bool

    public init(
        steps: [Step],
        enforceLexicographicOrder: Bool = true,
        integration: MigrationHostIntegration<any DatabaseWriter, Database> = .init(),
        provenance: MigrationProvenance = MigrationProvenance(),
        log: (@Sendable (String) -> Void)? = nil
    ) throws {
        self.registry = try MigrationRegistry(
            steps: steps,
            enforceLexicographicOrder: enforceLexicographicOrder
        )
        self.integration = integration
        self.provenance = provenance
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

    /// Applies every pending step, each in its own transaction with its ledger row.
    ///
    /// First, in one transaction, the ledger is reconciled and every step whose superseded
    /// migrations are all applied is recorded as applied without running (see
    /// `recordSupersededSteps`). A step whose superseded migrations are only partly applied
    /// refuses the whole migration with `supersededChainIncomplete`.
    public func migrate(in writer: any DatabaseWriter) throws {
        try runBootstrapSchemaIfConfigured(in: writer)
        try recordSupersededSteps(in: writer, through: registry.steps.count)
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
        let targetCount = (migrationIdentifiers.firstIndex(of: targetIdentifier) ?? 0) + 1
        try recordSupersededSteps(in: writer, through: targetCount)

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

    /// A step is up when the database has its effect: applied, or everything it supersedes is.
    public func migrationStatus(in writer: any DatabaseWriter) throws -> [MigrationStatus] {
        let ledger = try writer.read { db in try MigrationLedgerStore.state(in: db) }
        return registry.steps.map { step in
            MigrationStatus(
                identifier: step.identifier,
                sourceFile: step.sourceFile,
                state: registry.standing(of: step, in: ledger).hasEffect ? .up : .down
            )
        }
    }

    /// Brings the ledger in line with `grdb_migrations`, the source of truth: an applied identifier
    /// without a row gets one with an unknown (NULL) revision and no provenance, and a row whose
    /// identifier is not applied is removed. Creates the ledger table if needed. `migrate` runs
    /// this first; a host also runs it when it opens a database, before `diff`.
    public func reconcileLedger(in writer: any DatabaseWriter) throws {
        try writer.write { db in try MigrationLedgerStore.reconcile(in: db) }
    }

    /// How the database's applied migrations differ from this runner's registry.
    ///
    /// `mainKnown` names the identifiers the host treats as released: their revisions are never
    /// compared. Reads only; an applied identifier without a ledger row counts as an unknown revision.
    public func diff(in reader: any DatabaseReader, mainKnown: Set<String>) throws -> LedgerDiff {
        let ledger = try reader.read { db in try MigrationLedgerStore.state(in: db) }
        return registry.diff(ledger, mainKnown: mainKnown)
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
        try reverse(in: writer) { ledger in
            let applied = registry.steps.filter { registry.standing(of: $0, in: ledger).hasEffect }.map(\.identifier)
            guard applied.contains(identifier) else { return [] }
            let latest = applied.last ?? identifier
            guard latest == identifier else {
                throw MigrationKitError.rollbackMustTargetLatestApplied(latestApplied: latest, requested: identifier)
            }
            return try planned([step], ledger: ledger)
        }
    }

    /// Reverses `target`'s migrations in one transaction: every step's rollback runs and leaves
    /// `grdb_migrations` and the ledger, with the migrations it supersedes, then the host's
    /// `didRollback` runs, or nothing changes at all.
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
        try reverse(in: writer) { ledger in
            let steps = try plan(target, ledger: ledger)
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
                let steps = try plan(target, ledger: try MigrationLedgerStore.state(in: db))
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
        try writer.read { db in try MigrationLedgerStore.state(in: db).applied }
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
        /// What leaves `grdb_migrations` and the ledger with it: its identifier and the applied
        /// migrations it supersedes, whose effect its rollback reverses too.
        let forgotten: [String]
    }

    private func plan(_ target: RollbackTarget, ledger: LedgerState) throws -> [PlannedRollback] {
        let appliedSteps = registry.steps.filter { registry.standing(of: $0, in: ledger).hasEffect }
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
        return try planned(reversed, ledger: ledger)
    }

    /// `steps`, newest first, once each has a rollback and no unknown migration was applied after
    /// the oldest of them. Unknown identifiers that sort before it are another branch's history,
    /// which these steps cannot depend on; without sorted identifiers, any unknown one refuses.
    /// A superseded identifier is not unknown: the registered step that supersedes it stands for it.
    private func planned(_ steps: [Step], ledger: LedgerState) throws -> [PlannedRollback] {
        guard let oldest = steps.last else { return [] }
        let newer = registry.unknownIdentifiers(in: ledger)
            .filter { !identifiersSortInOrder || $0 > oldest.identifier }
            .sorted()
        guard newer.isEmpty else {
            throw MigrationKitError.rollbackBlockedByUnknownMigrations(newer)
        }
        return try steps.map { step in
            guard let rollback = step.rollback else {
                throw MigrationKitError.rollbackNotDefined(step.identifier)
            }
            return PlannedRollback(
                identifier: step.identifier,
                sourceFile: step.sourceFile,
                rollback: rollback,
                forgotten: [step.identifier] + registry.supersededIdentifiers(of: step, in: ledger)
            )
        }
    }

    @discardableResult
    private func reverse(
        in writer: any DatabaseWriter,
        choosing choose: (LedgerState) throws -> [PlannedRollback]
    ) throws -> [String] {
        let reversed: [String] = try writer.writeWithoutTransaction { db in
            var reversed: [String] = []
            do {
                try db.inTransaction {
                    let steps = try choose(try MigrationLedgerStore.state(in: db))
                    guard !steps.isEmpty else { return .rollback }
                    for step in steps {
                        log?("↩️ Rolling back migration \(step.identifier) from \(step.sourceFile)")
                        try step.rollback(db)
                        for identifier in step.forgotten {
                            try MigrationLedgerStore.forget(identifier, in: db)
                        }
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

    /// Each step runs in GRDB's own transaction for it (`inTransaction(.immediate)`, also under
    /// deferred foreign key checks), which also inserts its `grdb_migrations` row; its ledger row is
    /// written in that transaction, so the three commit together or not at all.
    private func buildMigrator() -> GRDB.DatabaseMigrator {
        var migrator = GRDB.DatabaseMigrator()

        for step in registry.steps {
            migrator.registerMigration(step.identifier) { [provenance] db in
                log?("🧱 Applying migration \(step.identifier) from \(step.sourceFile)")
                try step.apply(db)
                try MigrationLedgerStore.record(
                    step.identifier, revision: step.revision, provenance: provenance, in: db)
            }
        }

        return migrator
    }

    /// Reconciles the ledger, then records each of the first `count` steps whose superseded
    /// migrations are all applied: a `grdb_migrations` row for its identifier (already there for a
    /// squash that kept its name) and a ledger row at its revision with this runner's provenance.
    /// Such a step never runs; the superseded rows stay, so a build that still registers them sees
    /// them applied, and rolling the step back removes them with it. All in one transaction; a step
    /// whose superseded migrations are only partly applied throws and leaves the database as it was.
    private func recordSupersededSteps(in writer: any DatabaseWriter, through count: Int) throws {
        try writer.write { db in
            try MigrationLedgerStore.reconcile(in: db)
            let ledger = try MigrationLedgerStore.state(in: db)
            for step in registry.steps.prefix(count) {
                switch registry.standing(of: step, in: ledger) {
                case .covered:
                    log?("⏭️ Recording \(step.identifier) as applied: everything it supersedes is applied")
                    try db.execute(
                        sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO grdb_migrations (identifier) VALUES (?)",
                        arguments: [step.identifier]
                    )
                    try MigrationLedgerStore.record(
                        step.identifier, revision: step.revision, provenance: provenance, in: db)
                case .chainIncomplete(let missing):
                    throw MigrationKitError.supersededChainIncomplete(
                        identifier: step.identifier,
                        missing: missing.map(\.description)
                    )
                case .applied, .revisionChanged, .behind:
                    break
                }
            }
        }
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
