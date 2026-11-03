import GRDB
import MigrationKit

/// The tables of the main schema and their columns: what a rollback can take data away with.
struct SchemaInventory {
    /// Each table's columns, in declaration order.
    let columnsByTable: [String: [String]]

    init(_ db: Database) throws {
        // `pragma_table_list` (SQLite 3.37) types a virtual table's shadow tables `shadow`: their
        // rows are the virtual table's, so it is counted once, under its own name.
        let tables = try String.fetchAll(
            db,
            sql: """
                SELECT name FROM pragma_table_list
                WHERE schema = 'main' AND type IN ('table', 'virtual') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
                """
        )
        var columnsByTable: [String: [String]] = [:]
        for table in tables {
            columnsByTable[table] = try db.columns(in: table).map(\.name)
        }
        self.columnsByTable = columnsByTable
    }

    /// The tables and columns this inventory has and `later` lacks, counted in `db`, which must
    /// still hold them. A removed table's columns are not listed again.
    func removals(
        leaving later: SchemaInventory,
        identifiers: [String],
        countedIn db: Database
    ) throws -> RollbackReport {
        var removedTables: [RollbackReport.RemovedTable] = []
        var removedColumns: [RollbackReport.RemovedColumn] = []
        for (table, columns) in columnsByTable.sorted(by: { $0.key < $1.key }) {
            let quotedTable = table.quotedDatabaseIdentifier
            guard let remaining = later.columnsByTable[table] else {
                let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(quotedTable)") ?? 0
                removedTables.append(.init(name: table, rowCount: rows))
                continue
            }
            for column in columns where !remaining.contains(column) {
                let values =
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM \(quotedTable) WHERE \(column.quotedDatabaseIdentifier) IS NOT NULL"
                    ) ?? 0
                removedColumns.append(.init(table: table, column: column, valueCount: values))
            }
        }
        return RollbackReport(identifiers: identifiers, removedTables: removedTables, removedColumns: removedColumns)
    }
}
