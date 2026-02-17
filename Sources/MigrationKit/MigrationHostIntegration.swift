public struct MigrationHostIntegration<Writer, Database>: Sendable {
    public var bootstrapSchema: (@Sendable (Database) throws -> Bool)?
    public var verifyIntegrity: (@Sendable (Database) throws -> Void)?
    public var verifyPostMigration: (@Sendable (Writer) throws -> Void)?

    public init(
        bootstrapSchema: (@Sendable (Database) throws -> Bool)? = nil,
        verifyIntegrity: (@Sendable (Database) throws -> Void)? = nil,
        verifyPostMigration: (@Sendable (Writer) throws -> Void)? = nil
    ) {
        self.bootstrapSchema = bootstrapSchema
        self.verifyIntegrity = verifyIntegrity
        self.verifyPostMigration = verifyPostMigration
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
