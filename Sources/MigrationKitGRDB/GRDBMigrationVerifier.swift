import Foundation
import GRDB
import MigrationKit

public enum GRDBMigrationVerificationError: LocalizedError, Equatable {
    case quickCheckFailed(result: String)
    case foreignKeyViolations(count: Int)
    case missingIndex(table: String, index: String)

    public var errorDescription: String? {
        switch self {
        case .quickCheckFailed(let result):
            return "SQLite quick_check failed: \(result)"
        case .foreignKeyViolations(let count):
            return "SQLite foreign_key_check found \(count) violation(s)"
        case .missingIndex(let table, let index):
            return "Missing required index '\(index)' on table '\(table)'"
        }
    }
}

public enum GRDBMigrationVerifier {
    public static func runPostMigrationChecks(
        in writer: any DatabaseWriter,
        requiredIndexes: [RequiredIndexSpec] = []
    ) throws {
        try writer.read { db in
            try verifyIntegrity(in: db)
            try verifyRequiredIndexes(in: db, requiredIndexes: requiredIndexes)
        }
    }

    public static func verifyIntegrity(in db: Database) throws {
        let quickCheckResult = try String.fetchOne(db, sql: "PRAGMA quick_check(1)") ?? "unknown"
        guard quickCheckResult.lowercased() == "ok" else {
            throw GRDBMigrationVerificationError.quickCheckFailed(result: quickCheckResult)
        }

        let foreignKeyViolations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        guard foreignKeyViolations.isEmpty else {
            throw GRDBMigrationVerificationError.foreignKeyViolations(count: foreignKeyViolations.count)
        }
    }

    public static func verifyRequiredIndexes(
        in db: Database,
        requiredIndexes: [RequiredIndexSpec]
    ) throws {
        for required in requiredIndexes {
            guard try db.tableExists(required.table) else { continue }

            let indexExists =
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1
                            FROM sqlite_master
                            WHERE type = 'index' AND tbl_name = ? AND name = ?
                        )
                        """,
                    arguments: [required.table, required.index]
                ) ?? false

            guard indexExists else {
                throw GRDBMigrationVerificationError.missingIndex(
                    table: required.table,
                    index: required.index
                )
            }
        }
    }
}
