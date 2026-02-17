import GRDB
import XCTest
@testable import MigrationKit
@testable import MigrationKitGRDB

final class GRDBMigrationRunnerTests: XCTestCase {
    func testMigrateStatusAndRollbackFlow() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()

        let initialStatus = try runner.migrationStatus(in: queue)
        XCTAssertEqual(initialStatus.map(\.state), [.down, .down])

        try runner.migrate(in: queue)
        let migratedStatus = try runner.migrationStatus(in: queue)
        XCTAssertEqual(migratedStatus.map(\.state), [.up, .up])

        try runner.rollbackLastMigration(in: queue)
        let rolledBackStatus = try runner.migrationStatus(in: queue)
        XCTAssertEqual(rolledBackStatus.map(\.state), [.up, .down])

        let hasTagsTable = try queue.read { db in
            try db.tableExists("tags")
        }
        XCTAssertFalse(hasTagsTable)
    }

    func testMigrateUpToAppliesPrefixOnly() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()

        try runner.migrate(in: queue, upTo: "0001_create_items")

        let status = try runner.migrationStatus(in: queue)
        XCTAssertEqual(status.map(\.state), [.up, .down])
        XCTAssertEqual(try runner.pendingMigrationIdentifiers(in: queue), ["0002_create_tags"])
    }

    func testUnknownMigrationTargetThrows() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()

        XCTAssertThrowsError(try runner.migrate(in: queue, upTo: "9999_missing")) { error in
            guard case MigrationKitError.unknownMigrationTarget(let target) = error else {
                return XCTFail("Expected unknownMigrationTarget, got \(error)")
            }
            XCTAssertEqual(target, "9999_missing")
        }
    }

    func testBootstrapSchemaRunsOncePerMigrationInvocation() throws {
        let integration = MigrationHostIntegration<any DatabaseWriter, Database>(
            bootstrapSchema: { db in
                try db.execute(
                    sql: "CREATE TABLE IF NOT EXISTS bootstrap_calls (id INTEGER PRIMARY KEY AUTOINCREMENT)"
                )
                try db.execute(sql: "INSERT INTO bootstrap_calls DEFAULT VALUES")
                return false
            }
        )
        let runner = try makeRunner(integration: integration)
        let queue = try DatabaseQueue()

        try runner.migrate(in: queue)

        let bootstrapCallCount = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bootstrap_calls") ?? 0
        }
        XCTAssertEqual(bootstrapCallCount, 1)
    }

    func testRollbackMigrationsRejectsNegativeStepCount() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()

        XCTAssertThrowsError(try runner.rollbackMigrations(in: queue, steps: -1)) { error in
            guard case MigrationKitError.rollbackStepCountMustBeNonNegative(let count) = error else {
                return XCTFail("Expected rollbackStepCountMustBeNonNegative, got \(error)")
            }
            XCTAssertEqual(count, -1)
        }
    }

    func testRollbackMigrationRequiresLatestAppliedMigration() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue)

        XCTAssertThrowsError(
            try runner.rollbackMigration(identifier: "0001_create_items", in: queue)
        ) { error in
            guard
                case MigrationKitError.rollbackMustTargetLatestApplied(
                    let latestApplied,
                    let requested
                ) = error
            else {
                return XCTFail("Expected rollbackMustTargetLatestApplied, got \(error)")
            }
            XCTAssertEqual(latestApplied, "0002_create_tags")
            XCTAssertEqual(requested, "0001_create_items")
        }
    }

    func testRollbackMigrationWithoutRollbackDefinitionThrows() throws {
        let steps: [MigrationStep<Database>] = [
            MigrationStep(
                identifier: "0001_create_items",
                sourceFile: "M0001_CreateItems.swift",
                apply: { db in
                    try db.create(table: "items", ifNotExists: true) { table in
                        table.column("id", .integer).primaryKey()
                    }
                }
            )
        ]
        let runner = try GRDBMigrationRunner(steps: steps)
        let queue = try DatabaseQueue()

        try runner.migrate(in: queue)

        XCTAssertThrowsError(
            try runner.rollbackMigration(identifier: "0001_create_items", in: queue)
        ) { error in
            guard case MigrationKitError.rollbackNotDefined(let identifier) = error else {
                return XCTFail("Expected rollbackNotDefined, got \(error)")
            }
            XCTAssertEqual(identifier, "0001_create_items")
        }
    }

    private func makeRunner(
        integration: MigrationHostIntegration<any DatabaseWriter, Database> = .init()
    ) throws -> GRDBMigrationRunner {
        try GRDBMigrationRunner(steps: makeSteps(), integration: integration)
    }

    private func makeSteps() -> [MigrationStep<Database>] {
        [
            MigrationStep(
                identifier: "0001_create_items",
                sourceFile: "M0001_CreateItems.swift",
                apply: { db in
                    try db.create(table: "items", ifNotExists: true) { table in
                        table.column("id", .integer).primaryKey()
                        table.column("name", .text).notNull()
                    }
                },
                rollback: { db in
                    try GRDBMigrationSQLHelpers.dropTableIfExists("items", in: db)
                }
            ),
            MigrationStep(
                identifier: "0002_create_tags",
                sourceFile: "M0002_CreateTags.swift",
                apply: { db in
                    try db.create(table: "tags", ifNotExists: true) { table in
                        table.column("id", .integer).primaryKey()
                        table.column("item_id", .integer).notNull()
                        table.column("label", .text).notNull()
                    }
                },
                rollback: { db in
                    try GRDBMigrationSQLHelpers.dropTableIfExists("tags", in: db)
                }
            ),
        ]
    }
}
