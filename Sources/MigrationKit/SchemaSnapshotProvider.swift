public protocol SchemaSnapshotProvider {
    associatedtype Snapshot
    func generateCanonicalSnapshot() throws -> Snapshot
}
