import GRDB
import XCTest
@testable import MigrationKit
@testable import MigrationKitGRDB

final class GRDBMigrationVerifierTests: XCTestCase {
    func testVerifyIntegrityPassesForHealthyDatabase() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "CREATE TABLE parents (id INTEGER PRIMARY KEY)")
            try db.execute(
                sql: """
                    CREATE TABLE children (
                        id INTEGER PRIMARY KEY,
                        parent_id INTEGER NOT NULL REFERENCES parents(id)
                    )
                    """
            )
            try db.execute(sql: "INSERT INTO parents (id) VALUES (1)")
            try db.execute(sql: "INSERT INTO children (id, parent_id) VALUES (1, 1)")
        }

        try queue.read { db in
            try GRDBMigrationVerifier.verifyIntegrity(in: db)
        }
    }

    func testVerifyIntegrityThrowsOnForeignKeyViolations() throws {
        let queue = try DatabaseQueue()
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "CREATE TABLE parents (id INTEGER PRIMARY KEY)")
            try db.execute(
                sql: """
                    CREATE TABLE children (
                        id INTEGER PRIMARY KEY,
                        parent_id INTEGER NOT NULL REFERENCES parents(id)
                    )
                    """
            )
            try db.execute(sql: "INSERT INTO children (id, parent_id) VALUES (1, 999)")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        XCTAssertThrowsError(
            try queue.read { db in
                try GRDBMigrationVerifier.verifyIntegrity(in: db)
            }
        ) { error in
            guard case GRDBMigrationVerificationError.foreignKeyViolations(let count) = error else {
                return XCTFail("Expected foreignKeyViolations, got \(error)")
            }
            XCTAssertEqual(count, 1)
        }
    }

    func testVerifyRequiredIndexesThrowsWhenIndexIsMissing() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        }

        XCTAssertThrowsError(
            try queue.read { db in
                try GRDBMigrationVerifier.verifyRequiredIndexes(
                    in: db,
                    requiredIndexes: [.init(table: "items", index: "idx_items_name")]
                )
            }
        ) { error in
            guard case GRDBMigrationVerificationError.missingIndex(let table, let index) = error else {
                return XCTFail("Expected missingIndex, got \(error)")
            }
            XCTAssertEqual(table, "items")
            XCTAssertEqual(index, "idx_items_name")
        }
    }

    func testVerifyRequiredIndexesPassesWhenIndexExists() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
            try db.execute(sql: "CREATE INDEX idx_items_name ON items(name)")
        }

        try queue.read { db in
            try GRDBMigrationVerifier.verifyRequiredIndexes(
                in: db,
                requiredIndexes: [.init(table: "items", index: "idx_items_name")]
            )
        }
    }
}
