import VispaceCore

/// One transition boundary for query, relation, placement and route modes.
/// Controllers retain their own cancellation/join registries for data deletion.
@MainActor
struct SpatialInteractionCoordinator {
    let cancelObjectQuery: () -> Void
    let cancelRelationQuery: () -> Void
    let cancelPlacement: () -> Void
    let clearRoute: () -> Void
    let submitObjectQuery: (String) -> Void
    let submitRelationQuery: (String) -> Void
    let evaluatePlacement: (FurnitureKind) -> Void

    func dismiss() {
        cancelObjectQuery()
        cancelRelationQuery()
        cancelPlacement()
        clearRoute()
    }

    @discardableResult
    func perform(_ command: SpatialCommand) -> SpatialCommandRejection? {
        dismiss()
        switch command {
        case .objectQuery(let text): submitObjectQuery(text)
        case .relationQuery(let text): submitRelationQuery(text)
        case .placement(let kind): evaluatePlacement(kind)
        case .rejected(let reason): return reason
        }
        return nil
    }
}
