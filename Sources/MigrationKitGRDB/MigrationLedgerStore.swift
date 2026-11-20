import Foundation
import GRDB
import MigrationKit

/// The `archive_migration_ledger` table: one row per applied identifier, with the revision it ran
/// at (NULL when unknown) and the build that applied it. `grdb_migrations` stays the source of
/// truth for what is applied; the ledger only describes it.
enum MigrationLedgerStore {
    static let table = "archive_migration_ledger"

    static func createIfNeeded(in db: Database) throws {
        try db.execute(
            sql: """
                CREATE TABLE IF NOT EXISTS \(table) (
                    identifier TEXT PRIMARY KEY,
                    revision INTEGER,
                    applied_commit TEXT,
                    applied_branch TEXT,
                    applied_at REAL NOT NULL
                )
                """
        )
    }

    /// Whether `reconcile` would change anything: no ledger table, an applied identifier without
    /// a row, or a row whose identifier is not applied.
    static func needsReconciling(in db: Database) throws -> Bool {
        guard try db.tableExists(table) else { return true }
        guard try db.tableExists("grdb_migrations") else {
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table))") ?? false
        }
        return try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier NOT IN (SELECT identifier FROM \(table)))
                    OR EXISTS(SELECT 1 FROM \(table) WHERE identifier NOT IN (SELECT identifier FROM grdb_migrations))
                """
        ) ?? false
    }

    /// Gives every applied identifier a row (revision unknown when the ledger did not see it run)
    /// and removes rows whose identifier is no longer applied.
    static func reconcile(in db: Database) throws {
        try createIfNeeded(in: db)
        guard try db.tableExists("grdb_migrations") else {
            try db.execute(sql: "DELETE FROM \(table)")
            return
        }
        try db.execute(
            sql: """
                INSERT INTO \(table) (identifier, revision, applied_commit, applied_branch, applied_at)
                SELECT identifier, NULL, NULL, NULL, ? FROM grdb_migrations
                WHERE identifier NOT IN (SELECT identifier FROM \(table))
                """,
            arguments: [Date().timeIntervalSince1970]
        )
        try db.execute(
            sql: "DELETE FROM \(table) WHERE identifier NOT IN (SELECT identifier FROM grdb_migrations)"
        )
    }

    static func record(_ identifier: String, revision: Int, provenance: MigrationProvenance, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO \(table) (identifier, revision, applied_commit, applied_branch, applied_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(identifier) DO UPDATE SET
                    revision = excluded.revision,
                    applied_commit = excluded.applied_commit,
                    applied_branch = excluded.applied_branch,
                    applied_at = excluded.applied_at
                """,
            arguments: [identifier, revision, provenance.commit, provenance.branch, Date().timeIntervalSince1970]
        )
    }

    /// Removes `identifier` from `grdb_migrations` and from the ledger, if it has one.
    static func forget(_ identifier: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [identifier])
        if try db.tableExists(table) {
            try db.execute(sql: "DELETE FROM \(table) WHERE identifier = ?", arguments: [identifier])
        }
    }

    /// What `grdb_migrations` holds, with the revisions the ledger knows. Without a ledger every
    /// revision is unknown; a ledger row for an identifier that is not applied is ignored.
    static func state(in db: Database) throws -> LedgerState {
        guard try db.tableExists("grdb_migrations") else { return LedgerState(applied: [], revisions: [:]) }
        let applied = Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
        var revisions: [String: Int] = [:]
        if try db.tableExists(table) {
            let rows = try Row.fetchAll(db, sql: "SELECT identifier, revision FROM \(table) WHERE revision IS NOT NULL")
            for row in rows {
                let identifier: String = row["identifier"]
                if applied.contains(identifier) { revisions[identifier] = row["revision"] }
            }
        }
        return LedgerState(applied: applied, revisions: revisions)
    }
}
