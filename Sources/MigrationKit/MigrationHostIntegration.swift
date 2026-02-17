public struct MigrationHostIntegration<Writer, Database>: @unchecked Sendable {
    public var bootstrapSchema: ((Database) throws -> Bool)?
    public var verifyIntegrity: ((Database) throws -> Void)?
    public var verifyPostMigration: ((Writer) throws -> Void)?

    public init(
        bootstrapSchema: ((Database) throws -> Bool)? = nil,
        verifyIntegrity: ((Database) throws -> Void)? = nil,
        verifyPostMigration: ((Writer) throws -> Void)? = nil
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
