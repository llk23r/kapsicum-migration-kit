public enum MigrationState: String, Sendable {
    case up
    case down
}

public struct MigrationStatus: Equatable, Sendable {
    public let identifier: String
    public let sourceFile: String
    public let state: MigrationState

    public init(identifier: String, sourceFile: String, state: MigrationState) {
        self.identifier = identifier
        self.sourceFile = sourceFile
        self.state = state
    }
}

public struct MigrationStep<Database>: Sendable {
    public let identifier: String
    public let sourceFile: String
    public let apply: @Sendable (Database) throws -> Void
    public let rollback: (@Sendable (Database) throws -> Void)?

    public init(
        identifier: String,
        sourceFile: String,
        apply: @escaping @Sendable (Database) throws -> Void,
        rollback: (@Sendable (Database) throws -> Void)? = nil
    ) {
        self.identifier = identifier
        self.sourceFile = sourceFile
        self.apply = apply
        self.rollback = rollback
    }
}
