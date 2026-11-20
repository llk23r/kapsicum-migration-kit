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
    /// Which definition of `identifier` this is. A step is frozen once it has run anywhere that
    /// matters; a definition that must change anyway (a squash on merge) takes the next revision.
    /// The ledger records the revision each step ran at.
    public let revision: Int
    /// The migrations this step replaces. A database that applied all of them has this step's
    /// effect: the step counts as applied there and does not run, and they do not count as unknown.
    public let supersedes: [MigrationReference]
    public let apply: @Sendable (Database) throws -> Void
    public let rollback: (@Sendable (Database) throws -> Void)?

    public init(
        identifier: String,
        sourceFile: String,
        revision: Int = 1,
        supersedes: [MigrationReference] = [],
        apply: @escaping @Sendable (Database) throws -> Void,
        rollback: (@Sendable (Database) throws -> Void)? = nil
    ) {
        self.identifier = identifier
        self.sourceFile = sourceFile
        self.revision = revision
        self.supersedes = supersedes
        self.apply = apply
        self.rollback = rollback
    }
}
