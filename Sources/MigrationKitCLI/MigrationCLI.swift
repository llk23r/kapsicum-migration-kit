import ArgumentParser
import Foundation
import GRDB
import MigrationKit
import MigrationKitGRDB

public struct MigrationDatabaseOpenOptions: Equatable, Sendable {
    public let dbPath: String?
    public let password: String?
    public let keychainService: String?
    public let keychainAccount: String?

    public init(
        dbPath: String? = nil,
        password: String? = nil,
        keychainService: String? = nil,
        keychainAccount: String? = nil
    ) {
        self.dbPath = dbPath
        self.password = password
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }
}

public struct MigrationCLIHost: Sendable {
    public let runner: GRDBMigrationRunner
    public let openWriter: @Sendable (_ options: MigrationDatabaseOpenOptions) throws -> any DatabaseWriter
    public let schemaSnapshotProvider: (any SchemaSnapshotProvider<String>)?
    /// Runs once a rollback is measured and before it changes the database, with what it will
    /// take away; the lines it returns are printed. A host keeps its copy of the database here,
    /// and a throw stops the rollback.
    public let prepareRollback: (@Sendable (_ writer: any DatabaseWriter, _ report: RollbackReport) throws -> [String])?

    public init(
        runner: GRDBMigrationRunner,
        openWriter: @escaping @Sendable (_ options: MigrationDatabaseOpenOptions) throws -> any DatabaseWriter,
        schemaSnapshotProvider: (any SchemaSnapshotProvider<String>)? = nil,
        prepareRollback: (@Sendable (_ writer: any DatabaseWriter, _ report: RollbackReport) throws -> [String])? = nil
    ) {
        self.runner = runner
        self.openWriter = openWriter
        self.schemaSnapshotProvider = schemaSnapshotProvider
        self.prepareRollback = prepareRollback
    }
}

public enum MigrationCLIError: LocalizedError {
    case hostUnavailable
    case schemaSnapshotNotConfigured

    public var errorDescription: String? {
        switch self {
        case .hostUnavailable:
            return "Migration CLI host is not installed"
        case .schemaSnapshotNotConfigured:
            return "Schema snapshot generation is not configured for this host"
        }
    }
}

public enum MigrationCLI {
    public static func run(
        arguments: [String],
        host: MigrationCLIHost,
        output: @escaping @Sendable (String) -> Void = { print($0) },
        errorOutput: @escaping @Sendable (String) -> Void = { message in
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    ) throws {
        try MigrationCLIContext.$current.withValue(
            .init(
                host: host,
                output: output,
                errorOutput: errorOutput
            )
        ) {
            let normalizedArguments: [String]
            if arguments.first == MigrationRootCommand.configuration.commandName {
                normalizedArguments = Array(arguments.dropFirst())
            } else {
                normalizedArguments = arguments
            }

            var command = try MigrationRootCommand.parseAsRoot(normalizedArguments)
            try command.run()
        }
    }
}

private struct MigrationCLIContextValues: Sendable {
    let host: MigrationCLIHost
    let output: @Sendable (String) -> Void
    let errorOutput: @Sendable (String) -> Void
}

private enum MigrationCLIContext {
    @TaskLocal static var current: MigrationCLIContextValues?

    static func requireHost() throws -> MigrationCLIHost {
        guard let current else {
            throw MigrationCLIError.hostUnavailable
        }
        return current.host
    }

    static func write(_ line: String) {
        current?.output(line)
    }
}

private struct MigrationDatabaseCommandOptions: ParsableArguments, Sendable {
    @Option(name: .long, help: "Database path override")
    var dbPath: String?

    @Option(name: .long, help: "Database password override")
    var password: String?

    @Option(name: .long, help: "Keychain service for password lookup")
    var keychainService: String?

    @Option(name: .long, help: "Keychain account for password lookup")
    var keychainAccount: String?

    var openOptions: MigrationDatabaseOpenOptions {
        MigrationDatabaseOpenOptions(
            dbPath: dbPath,
            password: password,
            keychainService: keychainService,
            keychainAccount: keychainAccount
        )
    }
}

private struct MigrationRootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrationkit",
        abstract: "ActiveRecord-inspired migration tooling for Swift",
        subcommands: [
            MigrateCommand.self,
            StatusCommand.self,
            RollbackCommand.self,
            VerifyCommand.self,
            SchemaDumpCommand.self,
        ]
    )
}

private struct MigrateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Run pending migrations, optionally up to a specific identifier"
    )

    @Option(name: .long, help: "Target migration identifier (like VERSION)")
    var to: String?

    @OptionGroup
    var databaseOptions: MigrationDatabaseCommandOptions

    mutating func run() throws {
        let host = try MigrationCLIContext.requireHost()
        let writer = try host.openWriter(databaseOptions.openOptions)

        if let to {
            try host.runner.migrate(in: writer, upTo: to)
            MigrationCLIContext.write("✅ Migrated up to \(to)")
        } else {
            try host.runner.migrate(in: writer)
            MigrationCLIContext.write(
                "✅ Migrated to latest (\(host.runner.migrationIdentifiers.last ?? "none"))"
            )
        }

        let pending = try host.runner.pendingMigrationIdentifiers(in: writer)
        if pending.isEmpty {
            MigrationCLIContext.write("ℹ️ Pending migrations: 0")
        } else {
            MigrationCLIContext.write("ℹ️ Pending migrations: \(pending.count)")
            pending.forEach { MigrationCLIContext.write("  - \($0)") }
        }
    }
}

private struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show up/down status for all registered migrations"
    )

    @OptionGroup
    var databaseOptions: MigrationDatabaseCommandOptions

    mutating func run() throws {
        let host = try MigrationCLIContext.requireHost()
        let writer = try host.openWriter(databaseOptions.openOptions)
        let statuses = try host.runner.migrationStatus(in: writer)

        MigrationCLIContext.write("STATUS  MIGRATION                             SOURCE")
        MigrationCLIContext.write(
            "------  ------------------------------------  ---------------------------------------------------------------"
        )
        for status in statuses {
            let state = status.state == .up ? "up  " : "down"
            let paddedID = status.identifier.padding(
                toLength: 36,
                withPad: " ",
                startingAt: 0
            )
            MigrationCLIContext.write("\(state)  \(paddedID)  \(status.sourceFile)")
        }

        let pendingCount = statuses.filter { $0.state == .down }.count
        MigrationCLIContext.write("\nℹ️ Pending: \(pendingCount)")
    }
}

private struct RollbackCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "Reverse applied migrations, newest first, in one transaction"
    )

    @Option(name: .long, help: "Number of migrations to roll back (default 1)")
    var step: Int?

    @Option(name: .long, help: "Roll back every migration applied after this identifier, which stays applied")
    var to: String?

    @Flag(name: .long, help: "Show what the rollback would take away, and change nothing")
    var dryRun = false

    @OptionGroup
    var databaseOptions: MigrationDatabaseCommandOptions

    func validate() throws {
        if step != nil, to != nil {
            throw ValidationError("Pass --step or --to, not both.")
        }
    }

    mutating func run() throws {
        let host = try MigrationCLIContext.requireHost()
        let writer = try host.openWriter(databaseOptions.openOptions)
        let target = to.map(RollbackTarget.to) ?? .steps(step ?? 1)

        let report = try host.runner.rollbackReport(target, in: writer)
        guard !report.identifiers.isEmpty else {
            MigrationCLIContext.write("ℹ️ Nothing to roll back")
            return
        }
        report.descriptionLines.forEach(MigrationCLIContext.write)
        if dryRun {
            MigrationCLIContext.write("ℹ️ Dry run: the database is unchanged")
            return
        }

        try host.prepareRollback?(writer, report).forEach(MigrationCLIContext.write)
        let reversed = try host.runner.rollback(target, in: writer)
        MigrationCLIContext.write("↩️ Rolled back \(reversed.count) migration(s)")
    }
}

extension RollbackReport {
    fileprivate var descriptionLines: [String] {
        var lines = ["↩️ Reverses, newest first:"] + identifiers.map { "  - \($0)" }
        guard !removedTables.isEmpty || !removedColumns.isEmpty else {
            return lines + ["ℹ️ Takes away no table or column"]
        }
        lines.append("⚠️ Takes away, with what each holds:")
        lines += removedTables.map { "  - table \($0.name) (\($0.rowCount) rows)" }
        lines += removedColumns.map { "  - column \($0.table).\($0.column) (\($0.valueCount) values)" }
        return lines
    }
}

private struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Run post-migration verification checks"
    )

    @OptionGroup
    var databaseOptions: MigrationDatabaseCommandOptions

    mutating func run() throws {
        let host = try MigrationCLIContext.requireHost()
        let writer = try host.openWriter(databaseOptions.openOptions)
        try host.runner.runPostMigrationChecks(in: writer)
        MigrationCLIContext.write("✅ Database verification passed")
    }
}

private struct SchemaDumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schema-dump",
        abstract: "Generate canonical schema snapshot SQL"
    )

    @Option(name: .long, help: "Output path for schema snapshot")
    var output: String = "schema.snapshot.sql"

    mutating func run() throws {
        let host = try MigrationCLIContext.requireHost()
        guard let schemaSnapshotProvider = host.schemaSnapshotProvider else {
            throw MigrationCLIError.schemaSnapshotNotConfigured
        }
        let sql = try schemaSnapshotProvider.generateCanonicalSnapshot()
        let outputURL = URL(fileURLWithPath: output)
        try sql.write(to: outputURL, atomically: true, encoding: .utf8)
        MigrationCLIContext.write("✅ Schema snapshot written to \(outputURL.path)")
    }
}
