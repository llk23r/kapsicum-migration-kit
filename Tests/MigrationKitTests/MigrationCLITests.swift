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
