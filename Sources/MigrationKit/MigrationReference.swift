/// A migration named by identifier, optionally at one revision: `"0091_x"` or `"0091_x@1"`.
///
/// A step's `supersedes` lists these. Without a revision the reference matches the identifier at
/// any revision; with one, only an application recorded at that revision (or at an unknown one).
public struct MigrationReference: Hashable, Sendable, LosslessStringConvertible, ExpressibleByStringLiteral {
    public let identifier: String
    public let revision: Int?

    public init(identifier: String, revision: Int? = nil) {
        self.identifier = identifier
        self.revision = revision
    }

    /// Parses `"identifier"` or `"identifier@revision"`, where the revision is a positive integer.
    /// Returns nil for an empty identifier or a malformed revision.
    public init?(_ description: String) {
        guard let at = description.lastIndex(of: "@") else {
            guard !description.isEmpty else { return nil }
            self.init(identifier: description)
            return
        }
        let identifier = String(description[..<at])
        let digits = description[description.index(after: at)...]
        guard !identifier.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
            let revision = Int(digits), revision > 0
        else { return nil }
        self.init(identifier: identifier, revision: revision)
    }

    /// A literal that does not parse becomes an identifier as written, which `MigrationRegistry`
    /// then refuses (`invalidSupersession`), so a typo fails at registration, never silently.
    public init(stringLiteral value: String) {
        self = MigrationReference(value) ?? MigrationReference(identifier: value)
    }

    public var description: String {
        revision.map { "\(identifier)@\($0)" } ?? identifier
    }
}
