import Foundation
import GRDB
import XCTest
@testable import MigrationKit
@testable import MigrationKitCLI
@testable import MigrationKitGRDB

final class MigrationCLITests: XCTestCase {
    func testMigrateCommandPrintsSuccessAndPendingCount() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()
        let writerBox = DatabaseWriterBox(writer: queue)
        let outputRecorder = LineRecorder()

        let host = MigrationCLIHost(
            runner: runner,
            openWriter: { _ in writerBox.writer }
        )

        try MigrationCLI.run(
            arguments: ["migrationkit", "migrate"],
            host: host,
            output: { outputRecorder.append($0) },
            errorOutput: { outputRecorder.append($0) }
        )

        let output = outputRecorder.snapshot()
        XCTAssertTrue(output.contains { $0.contains("✅ Migrated to latest (0002_create_tags)") })
        XCTAssertTrue(output.contains("ℹ️ Pending migrations: 0"))
    }

    func testStatusCommandPrintsHeadersAndPendingSummary() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()
        let writerBox = DatabaseWriterBox(writer: queue)
        let outputRecorder = LineRecorder()

        let host = MigrationCLIHost(
            runner: runner,
            openWriter: { _ in writerBox.writer }
        )

        try MigrationCLI.run(
            arguments: ["migrationkit", "status"],
            host: host,
            output: { outputRecorder.append($0) },
            errorOutput: { outputRecorder.append($0) }
        )

        let output = outputRecorder.snapshot()
        XCTAssertTrue(output.contains("STATUS  MIGRATION                             SOURCE"))
        XCTAssertTrue(output.contains { $0.contains("0001_create_items") })
        XCTAssertTrue(output.contains { $0.contains("0002_create_tags") })
        XCTAssertTrue(output.contains { $0.contains("ℹ️ Pending: 2") })
    }

    func testDatabaseOptionsArePassedToHostOpenWriter() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()
        let writerBox = DatabaseWriterBox(writer: queue)
        let optionRecorder = MigrationOptionsRecorder()

        let host = MigrationCLIHost(
            runner: runner,
            openWriter: { options in
                optionRecorder.record(options)
                return writerBox.writer
            }
        )

        try MigrationCLI.run(
            arguments: [
                "migrationkit",
                "status",
                "--db-path", "/tmp/example.sqlite",
                "--password", "test-pass",
                "--keychain-service", "svc",
                "--keychain-account", "acct",
            ],
            host: host
        )

        XCTAssertEqual(
            optionRecorder.latest(),
            MigrationDatabaseOpenOptions(
                dbPath: "/tmp/example.sqlite",
                password: "test-pass",
                keychainService: "svc",
                keychainAccount: "acct"
            )
        )
    }

    func testSchemaDumpWritesSnapshotFromProvider() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()
        let writerBox = DatabaseWriterBox(writer: queue)
        let outputRecorder = LineRecorder()
        let snapshotSQL = "CREATE TABLE t (id INTEGER PRIMARY KEY);\n"
        let outputPath = NSTemporaryDirectory()
            .appending("/migration-cli-schema-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        let host = MigrationCLIHost(
            runner: runner,
            openWriter: { _ in writerBox.writer },
            schemaSnapshotProvider: StaticSnapshotProvider(snapshot: snapshotSQL)
        )

        try MigrationCLI.run(
            arguments: ["migrationkit", "schema-dump", "--output", outputPath],
            host: host,
            output: { outputRecorder.append($0) },
            errorOutput: { outputRecorder.append($0) }
        )

        let fileContents = try String(contentsOfFile: outputPath, encoding: .utf8)
        XCTAssertEqual(fileContents, snapshotSQL)
        XCTAssertTrue(outputRecorder.snapshot().contains { $0.contains("Schema snapshot written to") })
    }

    func testSchemaDumpThrowsWhenProviderNotConfigured() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()
        let writerBox = DatabaseWriterBox(writer: queue)
        let host = MigrationCLIHost(
            runner: runner,
            openWriter: { _ in writerBox.writer }
        )

        XCTAssertThrowsError(
            try MigrationCLI.run(
                arguments: ["migrationkit", "schema-dump"],
                host: host
            )
        ) { error in
            guard case MigrationCLIError.schemaSnapshotNotConfigured = error else {
                return XCTFail("Expected schemaSnapshotNotConfigured, got \(error)")
            }
        }
    }

    func testRollbackSaysWhatGoesLetsTheHostPrepareAndThenReverses() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO items (id, name) VALUES (1, 'a')")
            try db.execute(sql: "INSERT INTO tags (id, item_id, label) VALUES (1, 1, 'x'), (2, 1, 'y')")
        }
        let writerBox = DatabaseWriterBox(writer: queue)
        let output = LineRecorder()
        let host = MigrationCLIHost(
            runner: runner,
            openWriter: { _ in writerBox.writer },
            prepareRollback: { writer, report in
                let tagsStillThere = try writer.read { try $0.tableExists("tags") }
                output.append("prepare saw tags=\(tagsStillThere) for \(report.identifiers)")
                return ["📦 host kept a copy"]
            }
        )

        try MigrationCLI.run(
            arguments: ["migrationkit", "rollback", "--to", "0001_create_items"],
            host: host,
            output: { output.append($0) }
        )

        XCTAssertEqual(
            output.snapshot(),
            [
                "↩️ Reverses, newest first:",
                "  - 0002_create_tags",
                "⚠️ Takes away, with what each holds:",
                "  - table tags (2 rows)",
                "prepare saw tags=true for [\"0002_create_tags\"]",
                "📦 host kept a copy",
                "↩️ Rolled back 1 migration(s)",
            ]
        )
        XCTAssertFalse(try queue.read { try $0.tableExists("tags") })
    }

    func testDryRunSaysWhatWouldGoAndChangesNothing() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue)
        let writerBox = DatabaseWriterBox(writer: queue)
        let output = LineRecorder()
        let host = MigrationCLIHost(
            runner: runner,
            openWriter: { _ in writerBox.writer },
            prepareRollback: { _, _ in
                output.append("prepare ran")
                return []
            }
        )

        try MigrationCLI.run(
            arguments: ["migrationkit", "rollback", "--step", "2", "--dry-run"],
            host: host,
            output: { output.append($0) }
        )

        XCTAssertEqual(
            output.snapshot(),
            [
                "↩️ Reverses, newest first:",
                "  - 0002_create_tags",
                "  - 0001_create_items",
                "⚠️ Takes away, with what each holds:",
                "  - table items (0 rows)",
                "  - table tags (0 rows)",
                "ℹ️ Dry run: the database is unchanged",
            ]
        )
        XCTAssertEqual(try runner.migrationStatus(in: queue).map(\.state), [.up, .up])
    }

    func testRollbackRefusesWhenTheDatabaseChangesWhileTheHostPrepares() throws {
        let runner = try makeRunner()
        let queue = try DatabaseQueue()
        try runner.migrate(in: queue)
        let writerBox = DatabaseWriterBox(writer: queue)
        let host = MigrationCLIHost(
            runner: runner,
            openWriter: { _ in writerBox.writer },
            prepareRollback: { writer, _ in
                try runner.rollback(.steps(1), in: writer)  // another caller reverses tags meanwhile
                return []
            }
        )

        XCTAssertThrowsError(
            try MigrationCLI.run(arguments: ["migrationkit", "rollback"], host: host, output: { _ in })
        ) { error in
            XCTAssertEqual(
                error as? MigrationKitError,
                .rollbackPlanChanged(expected: ["0002_create_tags"], actual: ["0001_create_items"])
            )
        }
        XCTAssertEqual(try runner.migrationStatus(in: queue).map(\.state), [.up, .down], "items was never reported")
    }

    func testRollbackWithNothingAppliedSaysSoAndDoesNotPrepare() throws {
        let runner = try makeRunner()
        let writerBox = DatabaseWriterBox(writer: try DatabaseQueue())
        let output = LineRecorder()
        let host = MigrationCLIHost(
            runner: runner,
            openWriter: { _ in writerBox.writer },
            prepareRollback: { _, _ in
                output.append("prepare ran")
                return []
            }
        )

        try MigrationCLI.run(arguments: ["migrationkit", "rollback"], host: host, output: { output.append($0) })

        XCTAssertEqual(output.snapshot(), ["ℹ️ Nothing to roll back"])
    }

    func testRollbackTakesStepOrToButNotBoth() throws {
        let writerBox = DatabaseWriterBox(writer: try DatabaseQueue())
        let host = MigrationCLIHost(runner: try makeRunner(), openWriter: { _ in writerBox.writer })

        XCTAssertThrowsError(
            try MigrationCLI.run(
                arguments: ["migrationkit", "rollback", "--step", "1", "--to", "0001_create_items"],
                host: host
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Pass --step or --to, not both."), "\(error)")
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

private struct StaticSnapshotProvider: SchemaSnapshotProvider {
    let snapshot: String

    func generateCanonicalSnapshot() throws -> String {
        snapshot
    }
}

private final class DatabaseWriterBox: @unchecked Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }
}

private final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

private final class MigrationOptionsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var options: MigrationDatabaseOpenOptions?

    func record(_ options: MigrationDatabaseOpenOptions) {
        lock.lock()
        defer { lock.unlock() }
        self.options = options
    }

    func latest() -> MigrationDatabaseOpenOptions? {
        lock.lock()
        defer { lock.unlock() }
        return options
    }
}
