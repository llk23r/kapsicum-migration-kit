public protocol SchemaSnapshotProvider<Snapshot>: Sendable where Snapshot: Sendable {
    associatedtype Snapshot
    func generateCanonicalSnapshot() throws -> Snapshot
}
