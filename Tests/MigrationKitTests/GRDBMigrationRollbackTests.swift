import GRDB
import XCTest
@testable import MigrationKit
@testable import MigrationKitGRDB

final class GRDBMigrationRollbackTests: XCTestCase {
    private struct Failure: Error {}

    func testRollbackToReversesEveryLaterMigrationAndKeepsTheTarget() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue)

        let reversed = try runner.rollback(.to("0001_create_items"), in: queue)

        XCTAssertEqual(reversed, ["0003_create_tags", "0002_add_item_note"])
        XCTAssertEqual(try runner.migrationStatus(in: queue).map(\.state), [.up, .down, .down])
        try queue.read { db in
            XCTAssertFalse(try db.tableExists("tags"))
            XCTAssertEqual(try db.columns(in: "items").map(\.name), ["id", "name"])
        }
    }

    func testStepsBeyondWhatIsAppliedReverseEverythingApplied() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue, upTo: "0002_add_item_note")

        XCTAssertEqual(try runner.rollback(.steps(5), in: queue), ["0002_add_item_note", "0001_create_items"])
        XCTAssertEqual(try runner.rollback(.steps(1), in: queue), [], "nothing is left to reverse")
        XCTAssertFalse(try queue.read { try $0.tableExists("items") })
    }

    func testAFailingStepUndoesTheWholeRollbackAndTheSchemaCacheAgrees() throws {
        // 0003's rollback drops `tags`; 0002's then reads the schema, which caches `tags` as
        // gone, and fails. SQLite brings `tags` back with the rest of the transaction.
        let runner = try makeRunner(failingRollbackOf: "0002_add_item_note")
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue)

        XCTAssertThrowsError(try runner.rollback(.to("0001_create_items"), in: queue)) { error in
            XCTAssertTrue(error is Failure, "\(error)")
        }

        XCTAssertEqual(try runner.migrationStatus(in: queue).map(\.state), [.up, .up, .up])
        try queue.read { db in
            XCTAssertTrue(try db.tableExists("tags"), "the connection's schema cache describes the undone rollback")
            XCTAssertEqual(try db.columns(in: "items").map(\.name), ["id", "name", "note"])
        }
    }

    func testDidRollbackCommitsWithTheStepsOrNotAtAll() throws {
        let recording = MigrationHostIntegration<any DatabaseWriter, Database>(didRollback: { db in
            try db.execute(sql: "INSERT INTO host_ledger (event) VALUES ('rolled back')")
        })
        let runner = try makeRunner(integration: recording)
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue)

        try runner.rollback(.steps(1), in: queue)
        XCTAssertEqual(try ledgerEvents(in: queue), ["rolled back"])

        let failing = MigrationHostIntegration<any DatabaseWriter, Database>(didRollback: { db in
            try db.execute(sql: "INSERT INTO host_ledger (event) VALUES ('second')")
            throw Failure()
        })
        XCTAssertThrowsError(try makeRunner(integration: failing).rollback(.steps(1), in: queue))
        XCTAssertEqual(try ledgerEvents(in: queue), ["rolled back"], "the failed hook's row went with its rollback")
        XCTAssertEqual(try runner.migrationStatus(in: queue).map(\.state), [.up, .up, .down])
        XCTAssertEqual(try queue.read { try $0.columns(in: "items").map(\.name) }, ["id", "name", "note"])
    }

    func testAStepWithoutRollbackRefusesBeforeAnythingChanges() throws {
        let runner = try makeRunner(withoutRollback: "0002_add_item_note")
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue)

        XCTAssertThrowsError(try runner.rollback(.steps(2), in: queue)) { error in
            XCTAssertEqual(error as? MigrationKitError, .rollbackNotDefined("0002_add_item_note"))
        }
        XCTAssertThrowsError(try runner.rollbackReport(.steps(2), in: queue))
        XCTAssertTrue(try queue.read { try $0.tableExists("tags") }, "the newer step was not reversed alone")
        XCTAssertEqual(try runner.migrationStatus(in: queue).map(\.state), [.up, .up, .up])
    }

    func testAnUnknownMigrationAppliedLaterRefusesAndAnEarlierOneDoesNot() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('0000_abandoned_branch')")
        }

        XCTAssertEqual(try runner.rollback(.steps(1), in: queue), ["0003_create_tags"])

        try queue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('0004_from_a_newer_build')")
        }
        XCTAssertThrowsError(try runner.rollback(.steps(1), in: queue)) { error in
            XCTAssertEqual(
                error as? MigrationKitError,
                .rollbackBlockedByUnknownMigrations(["0004_from_a_newer_build"])
            )
        }
        XCTAssertEqual(try runner.migrationStatus(in: queue).map(\.state), [.up, .up, .down])
    }

    func testReportCountsWhatGoesAndChangesNothing() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO items (id, name, note) VALUES (1, 'a', 'kept'), (2, 'b', NULL)")
            try db.execute(sql: "INSERT INTO tags (id, item_id, label) VALUES (1, 1, 'x'), (2, 1, 'y'), (3, 2, 'z')")
        }
        let schemaBefore = try schema(of: queue)

        let report = try runner.rollbackReport(.to("0001_create_items"), in: queue)

        XCTAssertEqual(
            report,
            RollbackReport(
                identifiers: ["0003_create_tags", "0002_add_item_note"],
                removedTables: [.init(name: "tags", rowCount: 3)],
                removedColumns: [.init(table: "items", column: "note", valueCount: 1)]
            )
        )
        XCTAssertEqual(try schema(of: queue), schemaBefore)
        XCTAssertEqual(try runner.migrationStatus(in: queue).map(\.state), [.up, .up, .up])
        try queue.read { db in
            XCTAssertTrue(try db.tableExists("tags"), "the measuring savepoint left a coherent schema cache")
            XCTAssertEqual(try db.columns(in: "items").map(\.name), ["id", "name", "note"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags"), 3)
        }
    }

    func testReportCountsAVirtualTableOnceAndNotItsShadowTables() throws {
        let steps: [MigrationStep<Database>] = [
            MigrationStep(
                identifier: "0001_create_notes_search",
                sourceFile: "M0001.swift",
                apply: { db in try db.execute(sql: "CREATE VIRTUAL TABLE notes_search USING fts5(body)") },
                rollback: { db in try db.execute(sql: "DROP TABLE notes_search") }
            )
        ]
        let runner = try GRDBMigrationRunner(steps: steps)
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO notes_search (body) VALUES ('one'), ('two')")
        }

        let report = try runner.rollbackReport(.steps(1), in: queue)

        XCTAssertEqual(report.removedTables, [.init(name: "notes_search", rowCount: 2)])
        XCTAssertEqual(report.removedColumns, [])
    }

    func testPostMigrationChecksRunOnceAfterAMultiStepRollback() throws {
        let checks = MigrationHostIntegration<any DatabaseWriter, Database>(verifyPostMigration: { writer in
            try writer.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS check_runs (id INTEGER PRIMARY KEY)")
                try db.execute(sql: "INSERT INTO check_runs DEFAULT VALUES")
            }
        })
        let runner = try makeRunner(integration: checks)
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue)

        try runner.rollback(.to("0001_create_items"), in: queue)

        XCTAssertEqual(
            try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM check_runs") },
            2,
            "one run after migrating, one after the two-step rollback"
        )
    }

    // MARK: - Fixture

    /// `items`, then a `note` column on it, then `tags`. `items` comes with `host_ledger`, a table a
    /// host's `didRollback` writes to.
    private func makeRunner(
        integration: MigrationHostIntegration<any DatabaseWriter, Database> = .init(),
        failingRollbackOf failing: String? = nil,
        withoutRollback missing: String? = nil
    ) throws -> GRDBMigrationRunner {
        func step(
            _ identifier: String,
            apply: @escaping @Sendable (Database) throws -> Void,
            rollback: @escaping @Sendable (Database) throws -> Void
        ) -> MigrationStep<Database> {
            let fails = identifier == failing
            let reversal: @Sendable (Database) throws -> Void = { db in
                try rollback(db)
                if fails {
                    _ = try db.tableExists("tags")
                    throw Failure()
                }
            }
            return MigrationStep(
                identifier: identifier,
                sourceFile: "\(identifier).swift",
                apply: apply,
                rollback: identifier == missing ? nil : reversal
            )
        }
        return try GRDBMigrationRunner(
            steps: [
                step(
                    "0001_create_items",
                    apply: { db in
                        try db.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
                        try db.execute(sql: "CREATE TABLE host_ledger (event TEXT NOT NULL)")
                    },
                    rollback: { db in
                        try db.execute(sql: "DROP TABLE items")
                        try db.execute(sql: "DROP TABLE host_ledger")
                    }
                ),
                step(
                    "0002_add_item_note",
                    apply: { db in try db.execute(sql: "ALTER TABLE items ADD COLUMN note TEXT") },
                    rollback: { db in try db.execute(sql: "ALTER TABLE items DROP COLUMN note") }
                ),
                step(
                    "0003_create_tags",
                    apply: { db in
                        try db.execute(sql: "CREATE TABLE tags (id INTEGER PRIMARY KEY, item_id INTEGER, label TEXT)")
                    },
                    rollback: { db in try db.execute(sql: "DROP TABLE tags") }
                ),
            ],
            integration: integration
        )
    }

    private func ledgerEvents(in queue: DatabaseQueue) throws -> [String] {
        try queue.read { try String.fetchAll($0, sql: "SELECT event FROM host_ledger ORDER BY rowid") }
    }

    private func schema(of queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT type || ' ' || name || ' ' || IFNULL(sql, '') FROM sqlite_schema ORDER BY name"
            )
        }
    }
}
