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

public struct MigrationStep<Database>: @unchecked Sendable {
    public let identifier: String
    public let sourceFile: String
    public let apply: (Database) throws -> Void
    public let rollback: ((Database) throws -> Void)?

    public init(
        identifier: String,
        sourceFile: String,
        apply: @escaping (Database) throws -> Void,
        rollback: ((Database) throws -> Void)? = nil
    ) {
        self.identifier = identifier
        self.sourceFile = sourceFile
        self.apply = apply
        self.rollback = rollback
    }
}
