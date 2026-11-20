import GRDB
import XCTest

@testable import MigrationKit
@testable import MigrationKitGRDB

final class SquashEquivalenceTests: XCTestCase {
    func testASquashThatMatchesTheChainPasses() throws {
        let report = try SquashEquivalence.compare(
            base: base,
            chain: chain,
            squashed: squashed(),
            fixture: fixture
        )

        XCTAssertTrue(report.isEquivalent, report.description)
    }

    func testAColumnDefaultDifferenceIsReported() throws {
        let report = try SquashEquivalence.compare(
            base: base,
            chain: chain,
            squashed: squashed(colorDefault: "'blue'")
        )

        XCTAssertEqual(report.differences.count, 2, report.description)
        XCTAssertEqual(
            report.differences[0],
            "column labels.color: the chain has TEXT NOT NULL DEFAULT 'red', "
                + "the squashed step has TEXT NOT NULL DEFAULT 'blue'"
        )
        XCTAssertTrue(report.differences[1].hasPrefix("definition labels: the chain has"), report.description)
    }

    func testADroppedCheckConstraintIsReported() throws {
        let report = try SquashEquivalence.compare(base: base, chain: chain, squashed: squashed(checksText: false))

        XCTAssertEqual(
            report.differences,
            [
                "definition labels: the chain has create table labels(color text not null default'red',"
                    + "id integer primary key,item_id integer not null references items(id)on delete cascade,"
                    + "text text check(length(text)>0)), the squashed step has create table labels("
                    + "color text not null default'red',id integer primary key,item_id integer not null "
                    + "references items(id)on delete cascade,text text)"
            ]
        )
    }

    func testAMissingIndexIsReported() throws {
        let report = try SquashEquivalence.compare(base: base, chain: chain, squashed: squashed(index: false))

        XCTAssertEqual(
            report.differences,
            [
                "index labels_by_color: the chain has it (on labels (color) WHERE color!='red'), "
                    + "the squashed step does not"
            ]
        )
    }

    func testATriggerDifferenceIsReported() throws {
        let report = try SquashEquivalence.compare(
            base: base,
            chain: chain,
            squashed: squashed(triggerBody: "UPDATE items SET name = 'labelled' WHERE id = NEW.item_id")
        )

        XCTAssertEqual(report.differences.count, 1, report.description)
        XCTAssertTrue(report.differences[0].hasPrefix("trigger labels_touch_item: the chain has"), report.description)
    }

    func testFixtureRowCountsAreCompared() throws {
        let report = try SquashEquivalence.compare(
            base: base,
            chain: chain,
            squashed: squashed(seedsLabel: false),
            fixture: fixture
        )

        XCTAssertEqual(report.differences, ["rows labels: the chain has 1, the squashed step has 0"])
    }

    func testNormalizationIgnoresLayoutAndQuotingButNotLiterals() {
        XCTAssertEqual(
            SQLNormalizer.normalize("CREATE  TRIGGER \"t\"\n AFTER INSERT ON [items] -- why\n BEGIN SELECT 'A'; END;"),
            SQLNormalizer.normalize("create trigger t after insert on items begin select 'A' ; end")
        )
        XCTAssertNotEqual(SQLNormalizer.normalize("SELECT 'A'"), SQLNormalizer.normalize("SELECT 'a'"))
    }

    // MARK: - Fixture

    private let base: (Database) throws -> Void = { db in
        try db.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
    }

    private let fixture: (Database) throws -> Void = { db in
        try db.execute(sql: "INSERT INTO items (id, name) VALUES (1, 'one'), (2, 'two')")
    }

    /// `labels`, then its fix: a color with a default, an index, a trigger, and a seeded row.
    private var chain: [MigrationStep<Database>] {
        [
            MigrationStep(
                identifier: "0002_labels",
                sourceFile: "M0002.swift",
                apply: { db in
                    try db.execute(
                        sql: """
                            CREATE TABLE labels (
                                id INTEGER PRIMARY KEY,
                                item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                                text TEXT CHECK (length(text) > 0)
                            )
                            """
                    )
                    try db.execute(sql: "INSERT INTO labels (item_id, text) SELECT id, name FROM items WHERE id = 1")
                }
            ),
            MigrationStep(
                identifier: "0003_fix_labels",
                sourceFile: "M0003.swift",
                apply: { db in
                    try db.execute(sql: "ALTER TABLE labels ADD COLUMN color TEXT NOT NULL DEFAULT 'red'")
                    try db.execute(sql: "CREATE INDEX labels_by_color ON labels(color) WHERE color != 'red'")
                    try db.execute(
                        sql: """
                            CREATE TRIGGER labels_touch_item AFTER INSERT ON labels
                            BEGIN UPDATE items SET name = name WHERE id = NEW.item_id; END
                            """
                    )
                }
            ),
        ]
    }

    private func squashed(
        colorDefault: String = "'red'",
        checksText: Bool = true,
        index: Bool = true,
        triggerBody: String = "UPDATE items SET name = name WHERE id = NEW.item_id",
        seedsLabel: Bool = true
    ) -> MigrationStep<Database> {
        MigrationStep(
            identifier: "0002_labels",
            sourceFile: "M0002.swift",
            revision: 2,
            supersedes: ["0002_labels@1", "0003_fix_labels"],
            apply: { db in
                try db.execute(
                    sql: """
                        CREATE TABLE "labels" (
                            "id" INTEGER PRIMARY KEY,
                            "item_id" INTEGER NOT NULL REFERENCES "items"("id") ON DELETE CASCADE,
                            "text" TEXT\(checksText ? " CHECK (length(\"text\") > 0)" : ""),
                            "color" TEXT NOT NULL DEFAULT \(colorDefault)
                        )
                        """
                )
                if index {
                    try db.execute(
                        sql: "CREATE INDEX \"labels_by_color\" ON \"labels\" (\"color\") WHERE \"color\" != 'red'")
                }
                try db.execute(
                    sql: "CREATE TRIGGER labels_touch_item AFTER INSERT ON labels BEGIN \(triggerBody); END"
                )
                if seedsLabel {
                    try db.execute(sql: "INSERT INTO labels (item_id, text) SELECT id, name FROM items WHERE id = 1")
                }
            }
        )
    }
}
