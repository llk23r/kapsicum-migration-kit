/// Which applied migrations a rollback reverses.
public enum RollbackTarget: Equatable, Sendable {
    /// The newest `count` applied migrations.
    case steps(Int)
    /// Every applied migration registered after `identifier`, which itself stays applied.
    case to(String)
}

/// What a rollback takes away with the schema, measured before the database changes.
///
/// It names the tables and columns that no longer exist once the rollback's steps have run, and
/// how much each holds. A table a step renames is listed under the name it loses. Rows a step
/// deletes from a table that stays are not counted.
public struct RollbackReport: Equatable, Sendable {
    public struct RemovedTable: Equatable, Sendable {
        public let name: String
        public let rowCount: Int

        public init(name: String, rowCount: Int) {
            self.name = name
            self.rowCount = rowCount
        }
    }

    public struct RemovedColumn: Equatable, Sendable {
        public let table: String
        public let column: String
        /// The rows whose value in the column is not NULL.
        public let valueCount: Int

        public init(table: String, column: String, valueCount: Int) {
            self.table = table
            self.column = column
            self.valueCount = valueCount
        }
    }

    /// The migrations the rollback reverses, newest first.
    public let identifiers: [String]
    public let removedTables: [RemovedTable]
    public let removedColumns: [RemovedColumn]

    public init(identifiers: [String], removedTables: [RemovedTable], removedColumns: [RemovedColumn]) {
        self.identifiers = identifiers
        self.removedTables = removedTables
        self.removedColumns = removedColumns
    }
}
