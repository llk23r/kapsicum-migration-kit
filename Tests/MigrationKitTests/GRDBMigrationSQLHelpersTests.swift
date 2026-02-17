import GRDB
import XCTest
@testable import MigrationKitGRDB

final class GRDBMigrationSQLHelpersTests: XCTestCase {
    func testDropTableIfExistsIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }

        try queue.write { db in
            try GRDBMigrationSQLHelpers.dropTableIfExists("items", in: db)
            try GRDBMigrationSQLHelpers.dropTableIfExists("items", in: db)
        }

        let exists = try queue.read { db in
            try db.tableExists("items")
        }
        XCTAssertFalse(exists)
    }

    func testDropIndexIfExistsIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
            try db.execute(sql: "CREATE INDEX idx_items_name ON items(name)")
        }

        try queue.write { db in
            try GRDBMigrationSQLHelpers.dropIndexIfExists("idx_items_name", in: db)
            try GRDBMigrationSQLHelpers.dropIndexIfExists("idx_items_name", in: db)
        }

        let indexExists = try queue.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM sqlite_master
                        WHERE type = 'index' AND name = ?
                    )
                    """,
                arguments: ["idx_items_name"]
            ) ?? false
        }
        XCTAssertFalse(indexExists)
    }

    func testQuotedEscapesEmbeddedQuotes() {
        XCTAssertEqual(
            GRDBMigrationSQLHelpers.quoted("na\"me"),
            "\"na\"\"me\""
        )
    }
}
