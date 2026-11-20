import Foundation
import GRDB
import MigrationKit

/// Checks that a squashed step leaves the same schema as the chain it supersedes.
///
/// Each side gets its own in-memory database: the same `base` setup, then (for row counts) the same
/// `fixture`, then the chain's steps in order or the squashed step alone, each applied as
/// `GRDBMigrationRunner` applies it. The two schemas are compared object by object:
///
/// - tables (virtual, `WITHOUT ROWID`, `STRICT`), and each column's type, `NOT NULL`, default,
///   primary key position and hidden flag (`PRAGMA table_xinfo`);
/// - each table's `CREATE TABLE` text from `sqlite_schema`, normalized and with its column and
///   constraint list sorted, which is where `CHECK` constraints and other clauses live;
/// - foreign keys, with their actions;
/// - indexes: key columns with order and collation, uniqueness, partial `WHERE`, and the whole
///   statement for an expression index; constraint indexes by their columns;
/// - triggers and views, by their SQL normalized (whitespace, comments, identifier quoting and
///   case outside string literals);
/// - with a `fixture`, the row count of every table.
///
/// Not compared: column order. `grdb_migrations` and the ledger are ignored. A table's text
/// compares its column definitions as written (normalized), so `DEFAULT 1 NOT NULL` and
/// `NOT NULL DEFAULT 1` differ there even though their columns match.
public enum SquashEquivalence {
    public struct Report: Equatable, Sendable, CustomStringConvertible {
        /// One line per object that differs, sorted; empty when the schemas match.
        public let differences: [String]

        public var isEquivalent: Bool { differences.isEmpty }

        public var description: String {
            isEquivalent
                ? "The squashed step matches the chain."
                : (["The squashed step differs from the chain:"] + differences.map { "  - \($0)" })
                    .joined(separator: "\n")
        }
    }

    public static func compare(
        base: (Database) throws -> Void = { _ in },
        chain: [MigrationStep<Database>],
        squashed: MigrationStep<Database>,
        fixture: ((Database) throws -> Void)? = nil
    ) throws -> Report {
        let chainFacts = try facts(afterApplying: chain, base: base, fixture: fixture)
        let squashedFacts = try facts(afterApplying: [squashed], base: base, fixture: fixture)
        var differences: [String] = []
        for key in Set(chainFacts.keys).union(squashedFacts.keys).sorted() {
            switch (chainFacts[key], squashedFacts[key]) {
            case (let expected?, nil):
                differences.append("\(key): the chain has it (\(expected)), the squashed step does not")
            case (nil, let actual?):
                differences.append("\(key): the squashed step has it (\(actual)), the chain does not")
            case (let expected?, let actual?) where expected != actual:
                differences.append("\(key): the chain has \(expected), the squashed step has \(actual)")
            default:
                break
            }
        }
        return Report(differences: differences)
    }

    private static func facts(
        afterApplying steps: [MigrationStep<Database>],
        base: (Database) throws -> Void,
        fixture: ((Database) throws -> Void)?
    ) throws -> [String: String] {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try base(db)
            try fixture?(db)
        }
        var migrator = GRDB.DatabaseMigrator()
        for step in steps {
            migrator.registerMigration(step.identifier, migrate: step.apply)
        }
        try migrator.migrate(queue)
        return try queue.read { db in try SchemaFacts(db, countingRows: fixture != nil).facts }
    }
}

/// A schema as `object key → description`, which two databases can be compared by.
private struct SchemaFacts {
    private(set) var facts: [String: String] = [:]

    init(_ db: Database, countingRows: Bool) throws {
        let ignored = ["grdb_migrations", MigrationLedgerStore.table]
        let tables = try Row.fetchAll(
            db,
            sql: """
                SELECT name, type, wr, strict FROM pragma_table_list
                WHERE schema = 'main' AND type IN ('table', 'virtual')
                  AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name NOT IN (?, ?)
                ORDER BY name
                """,
            arguments: StatementArguments(ignored)
        )
        for table in tables {
            let name: String = table["name"]
            try describeTable(name, row: table, in: db)
            try describeColumns(of: name, in: db)
            try describeForeignKeys(of: name, in: db)
            try describeIndexes(of: name, in: db)
            if countingRows {
                let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(name.quotedDatabaseIdentifier)") ?? 0
                facts["rows \(name)"] = "\(rows)"
            }
        }
        for object in try Row.fetchAll(
            db,
            sql: "SELECT type, name, sql FROM sqlite_schema WHERE type IN ('trigger', 'view') AND sql IS NOT NULL"
        ) {
            let type: String = object["type"]
            let name: String = object["name"]
            facts["\(type) \(name)"] = SQLNormalizer.normalize(object["sql"])
        }
    }

    private mutating func describeTable(_ name: String, row: Row, in db: Database) throws {
        var description = "table"
        let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_schema WHERE name = ?", arguments: [name]) ?? ""
        if row["type"] as String == "virtual" {
            description = "virtual table \(SQLNormalizer.normalize(sql))"
        } else {
            facts["definition \(name)"] = SQLNormalizer.normalizeTable(sql)
        }
        if row["wr"] as Bool { description += " WITHOUT ROWID" }
        if row["strict"] as Bool { description += " STRICT" }
        facts["table \(name)"] = description
    }

    private mutating func describeColumns(of table: String, in db: Database) throws {
        let columns = try Row.fetchAll(
            db,
            sql: "SELECT name, type, \"notnull\", dflt_value, pk, hidden FROM pragma_table_xinfo(?)",
            arguments: [table]
        )
        for column in columns {
            let name: String = column["name"]
            let type: String = column["type"]
            var description = type.isEmpty ? "untyped" : type.uppercased()
            if column["notnull"] as Bool { description += " NOT NULL" }
            if let defaultValue = column["dflt_value"] as String? { description += " DEFAULT \(defaultValue)" }
            let primaryKey: Int = column["pk"]
            if primaryKey > 0 { description += " PRIMARY KEY (\(primaryKey))" }
            let hidden: Int = column["hidden"]
            if hidden != 0 { description += " hidden (\(hidden))" }
            facts["column \(table).\(name)"] = description
        }
    }

    private mutating func describeForeignKeys(of table: String, in db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, "table", "from", "to", on_update, on_delete
                FROM pragma_foreign_key_list(?) ORDER BY id, seq
                """,
            arguments: [table]
        )
        let keys = Dictionary(grouping: rows, by: { $0["id"] as Int })
        for (_, columns) in keys {
            let from = columns.map { $0["from"] as String }.joined(separator: ", ")
            let to = columns.map { ($0["to"] as String?) ?? "(primary key)" }.joined(separator: ", ")
            let first = columns[0]
            let parent: String = first["table"]
            let onUpdate: String = first["on_update"]
            let onDelete: String = first["on_delete"]
            facts["foreign key \(table)(\(from))"] =
                "REFERENCES \(parent)(\(to)) ON UPDATE \(onUpdate) ON DELETE \(onDelete)"
        }
    }

    private mutating func describeIndexes(of table: String, in db: Database) throws {
        let indexes = try Row.fetchAll(
            db,
            sql: "SELECT name, \"unique\", origin FROM pragma_index_list(?)",
            arguments: [table]
        )
        for index in indexes {
            let name: String = index["name"]
            let origin: String = index["origin"]
            let keyColumns = try Row.fetchAll(
                db,
                sql: "SELECT cid, name, \"desc\", coll FROM pragma_index_xinfo(?) WHERE key = 1 ORDER BY seqno",
                arguments: [name]
            )
            let columns = keyColumns.map { column -> String in
                var description = (column["name"] as String?) ?? "(expression)"
                if column["coll"] as String != "BINARY" { description += " COLLATE \(column["coll"] as String)" }
                if column["desc"] as Bool { description += " DESC" }
                return description
            }.joined(separator: ", ")
            guard origin == "c" else {
                let kind = origin == "pk" ? "primary key" : "unique constraint"
                facts["\(kind) \(table)(\(columns))"] = "index"
                continue
            }
            let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_schema WHERE name = ?", arguments: [name])
            let normalized = SQLNormalizer.normalize(sql ?? "")
            var description = "on \(table) (\(columns))"
            if index["unique"] as Bool { description += " UNIQUE" }
            if keyColumns.contains(where: { $0["cid"] as Int == -2 }) {
                description += " as \(normalized)"
            } else if let whereKeyword = normalized.range(
                of: #"(?<![\w$])where(?![\w$])"#,
                options: .regularExpression
            ) {
                description += " WHERE " + normalized[whereKeyword.upperBound...].trimmingCharacters(in: .whitespaces)
            }
            facts["index \(name)"] = description
        }
    }
}

/// SQL text reduced to what changes its meaning: comments dropped, whitespace collapsed to single
/// spaces between words, identifiers unquoted, and everything outside string literals lowercased.
enum SQLNormalizer {
    static func normalize(_ sql: String) -> String {
        var output = ""
        var separate = false
        var characters = Array(sql)[...]

        func append(_ text: String) {
            if separate, let last = output.last, let first = text.first, isWord(last), isWord(first) {
                output.append(" ")
            }
            separate = false
            output += text
        }

        while let character = characters.popFirst() {
            switch character {
            case _ where character.isWhitespace:
                separate = true
            case "-" where characters.first == "-":
                while let next = characters.popFirst(), next != "\n" {}
                separate = true
            case "/" where characters.first == "*":
                characters.removeFirst()
                while let next = characters.popFirst(), !(next == "*" && characters.first == "/") {}
                _ = characters.popFirst()
                separate = true
            case "'":
                append("'" + quoted(until: "'", in: &characters) + "'")
            case "\"", "`", "[":
                let identifier = quoted(until: character == "[" ? "]" : character, in: &characters).lowercased()
                separate = true
                append(identifier.allSatisfy(isWord) ? identifier : "\"\(identifier)\"")
                separate = true
            default:
                append(String(character).lowercased())
            }
        }
        while output.last == ";" { output.removeLast() }
        return output
    }

    /// `normalize(sql)` for a `CREATE TABLE`, with its parenthesized list of columns and constraints
    /// sorted, so that the order columns were added in does not count.
    static func normalizeTable(_ sql: String) -> String {
        var prefix = ""
        var elements: [String] = []
        var current = ""
        var suffix = ""
        var depth = 0
        var quote: Character?
        var characters = Array(normalize(sql))[...]
        while let character = characters.popFirst() {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "(" {
                depth += 1
                if depth == 1 {
                    prefix.append(character)
                    continue
                }
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    elements.append(current)
                    suffix = ")" + String(characters)
                    break
                }
            } else if character == ",", depth == 1 {
                elements.append(current)
                current = ""
                continue
            }
            if depth == 0 { prefix.append(character) } else { current.append(character) }
        }
        return prefix + elements.sorted().joined(separator: ",") + suffix
    }

    /// The text up to the closing `quote`, where a doubled quote stands for one, kept as written.
    private static func quoted(until quote: Character, in characters: inout ArraySlice<Character>) -> String {
        var text = ""
        while let next = characters.popFirst() {
            if next == quote {
                guard characters.first == quote, quote != "]" else { break }
                characters.removeFirst()
                text.append(contentsOf: quote == "'" ? "''" : String(quote))
                continue
            }
            text.append(next)
        }
        return text
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }
}
