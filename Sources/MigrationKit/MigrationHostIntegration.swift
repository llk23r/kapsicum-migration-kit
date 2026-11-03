public struct MigrationHostIntegration<Writer, Database>: Sendable {
    public var bootstrapSchema: (@Sendable (Database) throws -> Bool)?
    public var verifyIntegrity: (@Sendable (Database) throws -> Void)?
    public var verifyPostMigration: (@Sendable (Writer) throws -> Void)?
    /// Runs inside a rollback's transaction after its steps, so the host's own bookkeeping commits
    /// with the schema change or not at all.
    public var didRollback: (@Sendable (Database) throws -> Void)?

    public init(
        bootstrapSchema: (@Sendable (Database) throws -> Bool)? = nil,
        verifyIntegrity: (@Sendable (Database) throws -> Void)? = nil,
        verifyPostMigration: (@Sendable (Writer) throws -> Void)? = nil,
        didRollback: (@Sendable (Database) throws -> Void)? = nil
    ) {
        self.bootstrapSchema = bootstrapSchema
        self.verifyIntegrity = verifyIntegrity
        self.verifyPostMigration = verifyPostMigration
        self.didRollback = didRollback
    }
}

public struct RequiredIndexSpec: Equatable, Sendable {
    public let table: String
    public let index: String

    public init(table: String, index: String) {
        self.table = table
        self.index = index
    }
}
