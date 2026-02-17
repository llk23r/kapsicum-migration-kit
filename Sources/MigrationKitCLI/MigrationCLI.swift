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

public struct MigrationCLIHost {
    public let runner: GRDBMigrationRunner
    public let openWriter: (_ options: MigrationDatabaseOpenOptions) throws -> any DatabaseWriter
    public let generateSchemaSnapshot: (() throws -> String)?

    public init(
        runner: GRDBMigrationRunner,
        openWriter: @escaping (_ options: MigrationDatabaseOpenOptions) throws -> any DatabaseWriter,
        generateSchemaSnapshot: (() throws -> String)? = nil
    ) {
        self.runner = runner
        self.openWriter = openWriter
        self.generateSchemaSnapshot = generateSchemaSnapshot
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
        output: @escaping (String) -> Void = { print($0) },
        errorOutput: @escaping (String) -> Void = { message in
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    ) throws {
        MigrationCLIContext.install(
            host: host,
            output: output,
            errorOutput: errorOutput
        )
        defer { MigrationCLIContext.reset() }

        var command = try MigrationRootCommand.parseAsRoot(arguments)
        try command.run()
    }
}

private enum MigrationCLIContext {
    nonisolated(unsafe) static var host: MigrationCLIHost?
    nonisolated(unsafe) static var output: ((String) -> Void)?
    nonisolated(unsafe) static var errorOutput: ((String) -> Void)?

    static func install(
        host: MigrationCLIHost,
        output: @escaping (String) -> Void,
        errorOutput: @escaping (String) -> Void
    ) {
        self.host = host
        self.output = output
        self.errorOutput = errorOutput
    }

    static func reset() {
        host = nil
        output = nil
        errorOutput = nil
    }

    static func requireHost() throws -> MigrationCLIHost {
        guard let host else {
            throw MigrationCLIError.hostUnavailable
        }
        return host
    }

    static func write(_ line: String) {
        output?(line)
    }
}

private protocol UsesDatabaseOpenOptions {
    var dbPath: String? { get }
    var password: String? { get }
    var keychainService: String? { get }
    var keychainAccount: String? { get }
}

private extension UsesDatabaseOpenOptions {
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

private struct MigrateCommand: ParsableCommand, UsesDatabaseOpenOptions {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Run pending migrations, optionally up to a specific identifier"
    )

    @Option(name: .long, help: "Target migration identifier (like VERSION)")
    var to: String?

    @Option(name: .long, help: "Database path override")
    var dbPath: String?

    @Option(name: .long, help: "Database password override")
    var password: String?

    @Option(name: .long, help: "Keychain service for password lookup")
    var keychainService: String?

    @Option(name: .long, help: "Keychain account for password lookup")
    var keychainAccount: String?

    mutating func run() throws {
        let host = try MigrationCLIContext.requireHost()
        let writer = try host.openWriter(openOptions)

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

private struct StatusCommand: ParsableCommand, UsesDatabaseOpenOptions {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show up/down status for all registered migrations"
    )

    @Option(name: .long, help: "Database path override")
    var dbPath: String?

    @Option(name: .long, help: "Database password override")
    var password: String?

    @Option(name: .long, help: "Keychain service for password lookup")
    var keychainService: String?

    @Option(name: .long, help: "Keychain account for password lookup")
    var keychainAccount: String?

    mutating func run() throws {
        let host = try MigrationCLIContext.requireHost()
        let writer = try host.openWriter(openOptions)
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

private struct RollbackCommand: ParsableCommand, UsesDatabaseOpenOptions {
    static let configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "Rollback migration steps (newest-first)"
    )

    @Option(name: .long, help: "Number of migrations to rollback")
    var step: Int = 1

    @Option(name: .long, help: "Database path override")
    var dbPath: String?

    @Option(name: .long, help: "Database password override")
    var password: String?

    @Option(name: .long, help: "Keychain service for password lookup")
    var keychainService: String?

    @Option(name: .long, help: "Keychain account for password lookup")
    var keychainAccount: String?

    mutating func run() throws {
        let host = try MigrationCLIContext.requireHost()
        let writer = try host.openWriter(openOptions)
        try host.runner.rollbackMigrations(in: writer, steps: step)
        MigrationCLIContext.write("↩️ Rolled back \(step) migration step(s)")
    }
}

private struct VerifyCommand: ParsableCommand, UsesDatabaseOpenOptions {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Run post-migration verification checks"
    )

    @Option(name: .long, help: "Database path override")
    var dbPath: String?

    @Option(name: .long, help: "Database password override")
    var password: String?

    @Option(name: .long, help: "Keychain service for password lookup")
    var keychainService: String?

    @Option(name: .long, help: "Keychain account for password lookup")
    var keychainAccount: String?

    mutating func run() throws {
        let host = try MigrationCLIContext.requireHost()
        let writer = try host.openWriter(openOptions)
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
        guard let generateSchemaSnapshot = host.generateSchemaSnapshot else {
            throw MigrationCLIError.schemaSnapshotNotConfigured
        }

        let sql = try generateSchemaSnapshot()
        let outputURL = URL(fileURLWithPath: output)
        try sql.write(to: outputURL, atomically: true, encoding: .utf8)
        MigrationCLIContext.write("✅ Schema snapshot written to \(outputURL.path)")
    }
}
