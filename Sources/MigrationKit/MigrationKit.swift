import Foundation

public enum SemanticVersionError: Error, Equatable {
    case invalidFormat(String)
}

public struct SemanticVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public var description: String {
        "\(major).\(minor).\(patch)"
    }


    public init(_ value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else {
            throw SemanticVersionError.invalidFormat(value)
        }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public struct MigrationStep<State> {
    public let id: String
    public let version: SemanticVersion
    private let transform: (inout State) throws -> Void

    public init(
        id: String? = nil,
        version: SemanticVersion,
        transform: @escaping (inout State) throws -> Void
    ) {
        if let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.id = id
        } else {
            self.id = version.description
        }
        self.version = version
        self.transform = transform
    }

    public func apply(on state: inout State) throws {
        try transform(&state)
    }

    public init(
        id: String? = nil,
        version: String,
        transform: @escaping (inout State) throws -> Void
    ) throws {
        try self.init(id: id, version: SemanticVersion(version), transform: transform)
    }
}

public enum MigrationRunnerError: Error, Equatable {
    case duplicateVersion(SemanticVersion)
    case invalidRange(from: SemanticVersion, to: SemanticVersion)
}

public struct MigrationReport<State> {
    public let state: State
    public let appliedStepIDs: [String]
    public let startingVersion: SemanticVersion
    public let finalVersion: SemanticVersion
}

public struct MigrationRunner<State> {
    private let sortedSteps: [MigrationStep<State>]

    public init(steps: [MigrationStep<State>]) throws {
        let sorted = steps.sorted { $0.version < $1.version }
        var seen = Set<SemanticVersion>()

        for step in sorted where !seen.insert(step.version).inserted {
            throw MigrationRunnerError.duplicateVersion(step.version)
        }

        self.sortedSteps = sorted
    }

    public func migrate(
        _ initialState: State,
        from currentVersion: SemanticVersion,
        to targetVersion: SemanticVersion? = nil
    ) throws -> MigrationReport<State> {
        let resolvedTargetVersion = targetVersion ?? sortedSteps.last?.version ?? currentVersion
        guard resolvedTargetVersion >= currentVersion else {
            throw MigrationRunnerError.invalidRange(from: currentVersion, to: resolvedTargetVersion)
        }

        var state = initialState
        var appliedStepIDs: [String] = []
        var finalVersion = currentVersion

        for step in sortedSteps where step.version > currentVersion && step.version <= resolvedTargetVersion {
            try step.apply(on: &state)
            appliedStepIDs.append(step.id)
            finalVersion = step.version
        }

        return MigrationReport(
            state: state,
            appliedStepIDs: appliedStepIDs,
            startingVersion: currentVersion,
            finalVersion: finalVersion
        )
    }

    public func migrate(
        _ initialState: State,
        from currentVersion: String,
        to targetVersion: String? = nil
    ) throws -> MigrationReport<State> {
        try migrate(
            initialState,
            from: SemanticVersion(currentVersion),
            to: try targetVersion.map(SemanticVersion.init)
        )
    }
}
