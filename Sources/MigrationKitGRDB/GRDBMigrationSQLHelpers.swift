import Foundation
import GRDB

public enum GRDBMigrationSQLHelpers {
    public static func dropColumnIfExists(_ column: String, from table: String, in db: Database) throws {
        guard try db.tableExists(table) else { return }
        let columns = try db.columns(in: table)
        guard columns.contains(where: { $0.name == column }) else { return }

        try db.execute(sql: "ALTER TABLE \(quoted(table)) DROP COLUMN \(quoted(column))")
    }

    public static func dropIndexIfExists(_ indexName: String, in db: Database) throws {
        let exists =
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM sqlite_master
                        WHERE type = 'index' AND name = ?
                    )
                    """,
                arguments: [indexName]
            ) ?? false

        guard exists else { return }
        try db.execute(sql: "DROP INDEX \(quoted(indexName))")
    }

    public static func dropTableIfExists(_ table: String, in db: Database) throws {
        guard try db.tableExists(table) else { return }
        try db.execute(sql: "DROP TABLE \(quoted(table))")
    }

    public static func quoted(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
