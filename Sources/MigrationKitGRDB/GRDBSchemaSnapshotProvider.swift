import Foundation
import GRDB
import MigrationKit

public struct GRDBSchemaSnapshotProvider: SchemaSnapshotProvider {
    public typealias Snapshot = String

    private let migrate: (DatabaseQueue) throws -> Void
    private let postProcess: (String) -> String

    public init(
        migrate: @escaping (DatabaseQueue) throws -> Void,
        postProcess: @escaping (String) -> String = { $0 }
    ) {
        self.migrate = migrate
        self.postProcess = postProcess
    }

    public func generateCanonicalSnapshot() throws -> String {
        let queue = try DatabaseQueue()
        try migrate(queue)

        let sql = try queue.read { db in
            let statements = try String.fetchAll(
                db,
                sql: """
                SELECT sql
                FROM sqlite_master
                WHERE sql IS NOT NULL
                  AND name NOT LIKE 'sqlite_%'
                ORDER BY
                  CASE type
                    WHEN 'table' THEN 0
                    WHEN 'index' THEN 1
                    WHEN 'trigger' THEN 2
                    WHEN 'view' THEN 3
                    ELSE 4
                  END,
                  name
                """
            )

            let canonicalStatements = statements.map(Self.normalizeSQLStatement)
            return canonicalStatements.joined(separator: ";\n\n") + ";\n"
        }

        return postProcess(sql)
    }

    private static func normalizeSQLStatement(_ sql: String) -> String {
        sql
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
