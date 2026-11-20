import GRDB
import XCTest

@testable import MigrationKit
@testable import MigrationKitGRDB

final class MigrationLedgerTests: XCTestCase {
    private struct Failure: Error {}

    private struct LedgerRow: Equatable {
        let identifier: String
        let revision: Int?
        let commit: String?
        let branch: String?
    }

    // MARK: - Writing

    func testEachStepWritesItsRowWithItsRevisionAndTheHostsProvenance() throws {
        let provenance = MigrationProvenance(commit: "abc123", branch: "feat/notes")
        let runner = try GRDBMigrationRunner(
            steps: [items, note(revision: 3), tags],
            provenance: provenance
        )
        let queue = try DatabaseQueue()

        try runner.migrate(in: queue)

        XCTAssertEqual(
            try ledger(in: queue),
            [
                LedgerRow(identifier: "0001_items", revision: 1, commit: "abc123", branch: "feat/notes"),
                LedgerRow(identifier: "0002_note", revision: 3, commit: "abc123", branch: "feat/notes"),
                LedgerRow(identifier: "0003_tags", revision: 1, commit: "abc123", branch: "feat/notes"),
            ]
        )
        let appliedAt = try queue.read {
            try Double.fetchAll($0, sql: "SELECT applied_at FROM archive_migration_ledger")
        }
        XCTAssertTrue(appliedAt.allSatisfy { $0 > 0 })
    }

    func testAFailingStepLeavesNoLedgerRow() throws {
        let failing = MigrationStep<Database>(
            identifier: "0002_fails",
            sourceFile: "M0002.swift",
            apply: { db in
                try db.execute(sql: "CREATE TABLE half_done (id INTEGER PRIMARY KEY)")
                throw Failure()
            }
        )
        let runner = try GRDBMigrationRunner(steps: [items, failing])
        let queue = try DatabaseQueue()

        XCTAssertThrowsError(try runner.migrate(in: queue)) { XCTAssertTrue($0 is Failure, "\($0)") }

        XCTAssertEqual(try ledger(in: queue).map(\.identifier), ["0001_items"])
        XCTAssertEqual(try runner.appliedMigrationIdentifiers(in: queue), ["0001_items"])
        XCTAssertFalse(try queue.read { try $0.tableExists("half_done") })
    }

    func testRollbackRemovesItsRowsInItsOwnTransaction() throws {
        let runner = try GRDBMigrationRunner(steps: [items, note(), tags])
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue)

        try runner.rollback(.to("0001_items"), in: queue)
        XCTAssertEqual(try ledger(in: queue).map(\.identifier), ["0001_items"])

        try runner.migrate(in: queue)
        let failing = try GRDBMigrationRunner(
            steps: [items, note(), tags],
            integration: .init(didRollback: { _ in throw Failure() })
        )
        XCTAssertThrowsError(try failing.rollback(.steps(2), in: queue))
        XCTAssertEqual(
            try ledger(in: queue).map(\.identifier),
            ["0001_items", "0002_note", "0003_tags"],
            "the rows came back with the undone rollback"
        )
    }

    func testReconcileAddsUnknownRowsAndRemovesOrphans() throws {
        let runner = try GRDBMigrationRunner(steps: [items])
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('0000_before_the_ledger')")
            try db.execute(
                sql: """
                    INSERT INTO archive_migration_ledger (identifier, revision, applied_at)
                    VALUES ('0009_rolled_back_elsewhere', 2, 1)
                    """
            )
        }

        try runner.reconcileLedger(in: queue)

        XCTAssertEqual(
            try ledger(in: queue),
            [
                LedgerRow(identifier: "0000_before_the_ledger", revision: nil, commit: nil, branch: nil),
                LedgerRow(identifier: "0001_items", revision: 1, commit: nil, branch: nil),
            ]
        )
    }

    func testReconcileCreatesTheLedgerOnADatabaseThatNeverMigrated() throws {
        let runner = try GRDBMigrationRunner(steps: [items])
        let queue = try DatabaseQueue()

        try runner.reconcileLedger(in: queue)

        XCTAssertTrue(try queue.read { try $0.tableExists(GRDBMigrationRunner.ledgerTableName) })
        XCTAssertEqual(try ledger(in: queue), [])
        XCTAssertFalse(try queue.read { try $0.tableExists("grdb_migrations") })
    }

    func testMigratingAnUpToDateDatabaseWritesNothing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("archive.sqlite").path
        let runner = try GRDBMigrationRunner(steps: [items, note(), tags])
        let writer = try DatabaseQueue(path: path)
        let observer = try DatabaseQueue(path: path)
        try runner.migrate(in: writer)
        let dataVersion = { try observer.read { try Int.fetchOne($0, sql: "PRAGMA data_version") } }
        let versionBefore = try dataVersion()
        let changesBefore = try writer.read { try Int.fetchOne($0, sql: "SELECT total_changes()") }

        var statements: [String] = []
        writer.inDatabase { db in db.trace { statements.append("\($0)") } }

        try runner.migrate(in: writer)
        try runner.reconcileLedger(in: writer)

        writer.inDatabase { db in db.trace(nil) }
        XCTAssertEqual(try dataVersion(), versionBefore, "another connection saw a commit")
        XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "SELECT total_changes()") }, changesBefore)
        // GRDB's own `CREATE TABLE IF NOT EXISTS grdb_migrations` is the one statement that may look like a write.
        let writes = statements.filter { statement in
            let verb = statement.prefix(while: { !$0.isWhitespace }).uppercased()
            return ["INSERT", "UPDATE", "DELETE", "REPLACE", "CREATE", "DROP", "ALTER"].contains(verb)
                && !statement.hasPrefix("CREATE TABLE IF NOT EXISTS grdb_migrations")
        }
        XCTAssertEqual(writes, [])
    }

    func testMigrateUpToAnUnknownTargetThrowsAndWritesNothing() throws {
        let runner = try GRDBMigrationRunner(steps: [items, note()])
        let queue = try DatabaseQueue()

        XCTAssertThrowsError(try runner.migrate(in: queue, upTo: "0009_missing")) { error in
            XCTAssertEqual(error as? MigrationKitError, .unknownMigrationTarget("0009_missing"))
        }
        try queue.read { db in
            XCTAssertFalse(try db.tableExists("items"))
            XCTAssertFalse(try db.tableExists("grdb_migrations"))
            XCTAssertFalse(try db.tableExists(GRDBMigrationRunner.ledgerTableName))
        }
    }

    // MARK: - Diff

    func testDiffOfACurrentDatabaseIsEmpty() throws {
        let runner = try GRDBMigrationRunner(steps: [items, note(), tags])
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue)

        XCTAssertEqual(try runner.diff(in: queue, mainKnown: []), LedgerDiff())
    }

    func testDiffNamesStepsBehindAndIdentifiersAhead() throws {
        let runner = try GRDBMigrationRunner(steps: [items, note(), tags])
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue, upTo: "0001_items")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('0004_from_a_branch')")
        }

        XCTAssertEqual(
            try runner.diff(in: queue, mainKnown: []),
            LedgerDiff(behind: ["0002_note", "0003_tags"], ahead: ["0004_from_a_branch"])
        )
    }

    func testAnotherRevisionDivergesUnlessMainKnowsTheIdentifier() throws {
        let queue = try DatabaseQueue()
        try GRDBMigrationRunner(steps: [items, note(), tags]).migrate(in: queue)
        let edited = try GRDBMigrationRunner(steps: [items, note(revision: 2), tags])

        XCTAssertEqual(try edited.diff(in: queue, mainKnown: []), LedgerDiff(diverged: ["0002_note"]))
        XCTAssertEqual(try edited.diff(in: queue, mainKnown: ["0002_note"]), LedgerDiff())
    }

    func testAnUnknownRevisionNeverDiverges() throws {
        let queue = try DatabaseQueue()
        try GRDBMigrationRunner(steps: [items, note(), tags]).migrate(in: queue)
        try queue.write { db in
            try db.execute(sql: "UPDATE archive_migration_ledger SET revision = NULL WHERE identifier = '0002_note'")
        }
        let edited = try GRDBMigrationRunner(steps: [items, note(revision: 2), tags])

        XCTAssertEqual(try edited.diff(in: queue, mainKnown: []), LedgerDiff())

        try queue.write { db in try db.execute(sql: "DROP TABLE archive_migration_ledger") }
        XCTAssertEqual(try edited.diff(in: queue, mainKnown: []), LedgerDiff(), "no ledger: every revision unknown")
    }

    // MARK: - Supersession

    func testASquashThatKeptItsNameIsCurrentWhereTheChainRan() throws {
        let queue = try branchArchive()
        let squashed = try GRDBMigrationRunner(steps: [
            items, squashedLabels(supersedes: ["0002_labels@1", "0003_fix_labels"]),
        ])

        XCTAssertEqual(try squashed.diff(in: queue, mainKnown: []), LedgerDiff())
        XCTAssertEqual(try squashed.migrationStatus(in: queue).map(\.state), [.up, .up])
        XCTAssertFalse(try squashed.hasPendingMigrations(in: queue))
    }

    func testASquashUnderANewNameIsCurrentAndItsChainIsNotAhead() throws {
        let queue = try branchArchive()
        let squashed = try GRDBMigrationRunner(steps: [
            items,
            squashedLabels(identifier: "0002_labels_v2", revision: 1, supersedes: ["0002_labels", "0003_fix_labels"]),
        ])

        XCTAssertEqual(try squashed.diff(in: queue, mainKnown: []), LedgerDiff())
        XCTAssertEqual(try squashed.migrationStatus(in: queue).map(\.state), [.up, .up])
    }

    func testAReferenceAtAnotherRevisionDoesNotMatch() throws {
        let queue = try branchArchive()  // ran 0002_labels at revision 1
        let squashed = try GRDBMigrationRunner(steps: [
            items, squashedLabels(revision: 3, supersedes: ["0002_labels@2", "0003_fix_labels"]),
        ])

        XCTAssertEqual(
            try squashed.diff(in: queue, mainKnown: ["0002_labels"]),
            LedgerDiff(incomplete: ["0002_labels"]),
            "only part of what it supersedes matches, so the database ran something else"
        )
    }

    func testRenumberingOnMergeIsCurrentAndTheOldNumberIsNotAhead() throws {
        // A branch ran 0065_add_refs; main took 0065 first and merged the branch's step as 0066.
        let branchStep = refs(identifier: "0065_add_refs")
        let queue = try DatabaseQueue()
        try GRDBMigrationRunner(steps: [items, branchStep]).migrate(in: queue)
        let main = try GRDBMigrationRunner(
            steps: [items, reasoning, refs(identifier: "0066_add_refs", supersedes: ["0065_add_refs"])],
            provenance: MigrationProvenance(commit: "main1", branch: "main")
        )

        XCTAssertEqual(try main.diff(in: queue, mainKnown: []), LedgerDiff(behind: ["0065_agent_reasoning"]))

        try main.migrate(in: queue)

        XCTAssertEqual(try main.diff(in: queue, mainKnown: []), LedgerDiff())
        XCTAssertEqual(
            try ledger(in: queue).filter { $0.identifier.hasPrefix("0066") },
            [LedgerRow(identifier: "0066_add_refs", revision: 1, commit: "main1", branch: "main")]
        )
        XCTAssertEqual(
            try main.appliedMigrationIdentifiers(in: queue),
            ["0001_items", "0065_add_refs", "0065_agent_reasoning", "0066_add_refs"]
        )
    }

    func testMigrateNeverRunsASquashThatKeptItsNameWhereTheChainRan() throws {
        let queue = try branchArchive()
        // Run, the squash would fail: `labels` already exists.
        let squashed = try GRDBMigrationRunner(
            steps: [items, squashedLabels(supersedes: ["0002_labels@1", "0003_fix_labels"])],
            provenance: MigrationProvenance(commit: "main2", branch: "main")
        )

        try squashed.migrate(in: queue)

        XCTAssertEqual(
            try ledger(in: queue).filter { $0.identifier != "0001_items" },
            [
                LedgerRow(identifier: "0002_labels", revision: 1, commit: "branch", branch: "feat/labels"),
                LedgerRow(identifier: "0003_fix_labels", revision: 1, commit: "branch", branch: "feat/labels"),
            ],
            "GRDB already has 0002_labels, so its row keeps the revision that ran; the chain covers it"
        )
        XCTAssertEqual(
            try squashed.appliedMigrationIdentifiers(in: queue),
            ["0001_items", "0002_labels", "0003_fix_labels"],
            "the chain's rows stay, so a build that still registers it sees it applied"
        )
        XCTAssertEqual(try squashed.diff(in: queue, mainKnown: []), LedgerDiff())
    }

    func testMigrateRecordsASquashUnderANewNameInGRDBMigrations() throws {
        let queue = try branchArchive()
        let squashed = try GRDBMigrationRunner(steps: [
            items,
            squashedLabels(identifier: "0002_labels_v2", revision: 1, supersedes: ["0002_labels", "0003_fix_labels"]),
        ])

        try squashed.migrate(in: queue)

        XCTAssertEqual(
            try squashed.appliedMigrationIdentifiers(in: queue),
            ["0001_items", "0002_labels", "0002_labels_v2", "0003_fix_labels"]
        )
        XCTAssertEqual(try ledger(in: queue).first { $0.identifier == "0002_labels_v2" }?.revision, 1)
    }

    func testAPartlyAppliedChainDivergesAndRefusesToMigrate() throws {
        let queue = try DatabaseQueue()
        try GRDBMigrationRunner(steps: [items, labels, fixLabels]).migrate(in: queue, upTo: "0002_labels")
        let squashed = try GRDBMigrationRunner(steps: [
            items, squashedLabels(supersedes: ["0002_labels@1", "0003_fix_labels"]), tags,
        ])
        let ledgerBefore = try ledger(in: queue)

        XCTAssertEqual(
            try squashed.diff(in: queue, mainKnown: ["0002_labels"]),
            LedgerDiff(behind: ["0003_tags"], incomplete: ["0002_labels"])
        )
        XCTAssertThrowsError(try squashed.migrate(in: queue)) { error in
            XCTAssertEqual(
                error as? MigrationKitError,
                .supersededChainIncomplete(identifier: "0002_labels", missing: ["0003_fix_labels"])
            )
        }
        XCTAssertEqual(try ledger(in: queue), ledgerBefore)
        XCTAssertFalse(try queue.read { try $0.tableExists("tags") }, "nothing after it ran either")
    }

    func testRollingBackASquashTakesItsChainAlongAndASupersededIdentifierDoesNotBlock() throws {
        let queue = try branchArchive()
        let squashed = try GRDBMigrationRunner(steps: [
            items, squashedLabels(supersedes: ["0002_labels@1", "0003_fix_labels"]),
        ])
        try squashed.migrate(in: queue)

        // 0003_fix_labels sorts after 0002_labels and is not registered, yet it is not unknown.
        XCTAssertEqual(try squashed.rollback(.steps(1), in: queue), ["0002_labels"])

        XCTAssertEqual(try squashed.appliedMigrationIdentifiers(in: queue), ["0001_items"])
        XCTAssertEqual(try ledger(in: queue).map(\.identifier), ["0001_items"])
        XCTAssertFalse(try queue.read { try $0.tableExists("labels") })

        try squashed.migrate(in: queue)
        XCTAssertEqual(try ledger(in: queue).first { $0.identifier == "0002_labels" }?.revision, 2)
        XCTAssertEqual(try queue.read { try $0.columns(in: "labels").map(\.name) }, ["id", "text", "color"])
    }

    func testAnUnsupersededUnknownIdentifierStillBlocksARollback() throws {
        let queue = try branchArchive()
        // Supersedes only 0002_labels@1: 0003_fix_labels is another build's migration.
        let runner = try GRDBMigrationRunner(steps: [items, squashedLabels(revision: 2, supersedes: ["0002_labels@1"])])

        XCTAssertThrowsError(try runner.rollback(.steps(1), in: queue)) { error in
            XCTAssertEqual(error as? MigrationKitError, .rollbackBlockedByUnknownMigrations(["0003_fix_labels"]))
        }
    }

    // MARK: - Fixture

    private var items: MigrationStep<Database> {
        MigrationStep(
            identifier: "0001_items",
            sourceFile: "M0001.swift",
            apply: { db in try db.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)") },
            rollback: { db in try db.execute(sql: "DROP TABLE items") }
        )
    }

    private func note(revision: Int = 1) -> MigrationStep<Database> {
        MigrationStep(
            identifier: "0002_note",
            sourceFile: "M0002.swift",
            revision: revision,
            apply: { db in try db.execute(sql: "ALTER TABLE items ADD COLUMN note TEXT") },
            rollback: { db in try db.execute(sql: "ALTER TABLE items DROP COLUMN note") }
        )
    }

    private var tags: MigrationStep<Database> {
        MigrationStep(
            identifier: "0003_tags",
            sourceFile: "M0003.swift",
            apply: { db in try db.execute(sql: "CREATE TABLE tags (id INTEGER PRIMARY KEY)") },
            rollback: { db in try db.execute(sql: "DROP TABLE tags") }
        )
    }

    /// A branch's first try at `labels`, revision 1.
    private var labels: MigrationStep<Database> {
        MigrationStep(
            identifier: "0002_labels",
            sourceFile: "M0002.swift",
            apply: { db in try db.execute(sql: "CREATE TABLE labels (id INTEGER PRIMARY KEY, text TEXT)") },
            rollback: { db in try db.execute(sql: "DROP TABLE labels") }
        )
    }

    /// The branch's fix to it.
    private var fixLabels: MigrationStep<Database> {
        MigrationStep(
            identifier: "0003_fix_labels",
            sourceFile: "M0003.swift",
            apply: { db in try db.execute(sql: "ALTER TABLE labels ADD COLUMN color TEXT") },
            rollback: { db in try db.execute(sql: "ALTER TABLE labels DROP COLUMN color") }
        )
    }

    /// The one migration main gets for `labels`: the final shape.
    private func squashedLabels(
        identifier: String = "0002_labels",
        revision: Int = 2,
        supersedes: [MigrationReference]
    ) -> MigrationStep<Database> {
        MigrationStep(
            identifier: identifier,
            sourceFile: "M0002.swift",
            revision: revision,
            supersedes: supersedes,
            apply: { db in try db.execute(sql: "CREATE TABLE labels (id INTEGER PRIMARY KEY, text TEXT, color TEXT)") },
            rollback: { db in try db.execute(sql: "DROP TABLE labels") }
        )
    }

    private var reasoning: MigrationStep<Database> {
        MigrationStep(
            identifier: "0065_agent_reasoning",
            sourceFile: "M0065.swift",
            apply: { db in try db.execute(sql: "CREATE TABLE reasoning (id INTEGER PRIMARY KEY)") }
        )
    }

    private func refs(identifier: String, supersedes: [MigrationReference] = []) -> MigrationStep<Database> {
        MigrationStep(
            identifier: identifier,
            sourceFile: "M\(identifier.prefix(4)).swift",
            supersedes: supersedes,
            apply: { db in try db.execute(sql: "CREATE TABLE refs (id INTEGER PRIMARY KEY)") }
        )
    }

    /// An archive a branch build migrated through `labels` and its fix.
    private func branchArchive() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try GRDBMigrationRunner(
            steps: [items, labels, fixLabels],
            provenance: MigrationProvenance(commit: "branch", branch: "feat/labels")
        ).migrate(in: queue)
        return queue
    }

    private func ledger(in queue: DatabaseQueue) throws -> [LedgerRow] {
        try queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT identifier, revision, applied_commit, applied_branch
                    FROM archive_migration_ledger ORDER BY identifier
                    """
            ).map { row in
                LedgerRow(
                    identifier: row["identifier"],
                    revision: row["revision"],
                    commit: row["applied_commit"],
                    branch: row["applied_branch"]
                )
            }
        }
    }
}
