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

    private func makeRunner() throws -> GRDBMigrationRunner {
        let steps: [MigrationStep<Database>] = [
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

        return try GRDBMigrationRunner(steps: steps)
    }
}
