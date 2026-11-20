/// Where the build that applies migrations came from, recorded with each ledger row.
public struct MigrationProvenance: Equatable, Sendable {
    public let commit: String?
    public let branch: String?

    public init(commit: String? = nil, branch: String? = nil) {
        self.commit = commit
        self.branch = branch
    }
}

/// How a database's applied migrations differ from a build's registry.
public struct LedgerDiff: Equatable, Sendable {
    /// Registered steps the database has not applied, in registry order. A step whose superseded
    /// migrations are all applied is not behind.
    public var behind: [String]
    /// Applied identifiers the registry neither registers nor supersedes, sorted.
    public var ahead: [String]
    /// Registered steps the database applied as a different definition, in registry order: a
    /// recorded revision other than the registered one (never for `mainKnown` identifiers, never
    /// for an unknown revision), or only part of the migrations the step supersedes.
    public var diverged: [String]

    public init(behind: [String] = [], ahead: [String] = [], diverged: [String] = []) {
        self.behind = behind
        self.ahead = ahead
        self.diverged = diverged
    }
}

/// What a database records: the applied identifiers, and the revision each ran at where known.
package struct LedgerState: Sendable {
    package let applied: Set<String>
    /// An applied identifier without an entry ran at an unknown revision.
    package let revisions: [String: Int]

    package init(applied: Set<String>, revisions: [String: Int]) {
        self.applied = applied
        self.revisions = revisions
    }

    /// Applied, at the reference's revision or at an unknown one.
    package func matches(_ reference: MigrationReference) -> Bool {
        guard applied.contains(reference.identifier) else { return false }
        guard let wanted = reference.revision, let recorded = revisions[reference.identifier] else { return true }
        return wanted == recorded
    }
}

/// Where one registered step stands against a database.
package enum StepStanding: Equatable, Sendable {
    /// Applied at its revision, or at an unknown one.
    case applied
    /// Not applied itself, but everything it supersedes is: it has its effect, and does not run.
    case covered
    /// Applied at a recorded revision other than the registered one.
    case revisionChanged
    /// Part of what it supersedes is applied; these references are not.
    case chainIncomplete(missing: [MigrationReference])
    case behind

    /// Whether the database has the step's effect, as far as status and rollback are concerned.
    package var hasEffect: Bool {
        switch self {
        case .applied, .covered, .revisionChanged: return true
        case .chainIncomplete, .behind: return false
        }
    }
}

extension MigrationRegistry {
    package func standing(of step: MigrationStep<Database>, in ledger: LedgerState) -> StepStanding {
        let isApplied = ledger.applied.contains(step.identifier)
        let recorded = ledger.revisions[step.identifier]
        if isApplied, recorded == step.revision { return .applied }
        if !step.supersedes.isEmpty {
            let missing = step.supersedes.filter { !ledger.matches($0) }
            if missing.isEmpty { return .covered }
            if missing.count < step.supersedes.count { return .chainIncomplete(missing: missing) }
        }
        guard isApplied else { return .behind }
        return recorded == nil ? .applied : .revisionChanged
    }

    /// The applied identifiers `step` supersedes, other than its own: what its rollback also reverses.
    package func supersededIdentifiers(of step: MigrationStep<Database>, in ledger: LedgerState) -> [String] {
        step.supersedes
            .filter { $0.identifier != step.identifier && ledger.matches($0) }
            .map(\.identifier)
    }

    /// Applied identifiers this registry does not know: neither registered nor superseded.
    package func unknownIdentifiers(in ledger: LedgerState) -> Set<String> {
        let superseded = steps.flatMap { supersededIdentifiers(of: $0, in: ledger) }
        return ledger.applied.subtracting(identifiers).subtracting(superseded)
    }

    package func diff(_ ledger: LedgerState, mainKnown: Set<String>) -> LedgerDiff {
        var diff = LedgerDiff(ahead: unknownIdentifiers(in: ledger).sorted())
        for step in steps {
            switch standing(of: step, in: ledger) {
            case .applied, .covered:
                break
            case .behind:
                diff.behind.append(step.identifier)
            case .chainIncomplete:
                diff.diverged.append(step.identifier)
            case .revisionChanged:
                if !mainKnown.contains(step.identifier) { diff.diverged.append(step.identifier) }
            }
        }
        return diff
    }
}
