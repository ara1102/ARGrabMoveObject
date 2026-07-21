import RealityKit
import Combine

/// Minimal state holder for the standalone Call-Animal demo scene.
/// Scoped-down equivalent of a richer app's central AR manager: just enough
/// to place one animal and move it on demand.
class DemoARManager: ObservableObject {
    var cameraAnchor: AnchorEntity?

    /// Child of the plane anchor. All animal transforms are computed and
    /// applied relative to this entity rather than world space, so movement
    /// math stays consistent even though the plane anchor itself may be
    /// re-anchored by ARKit as tracking refines.
    let parentContainer = Entity()

    var animalEntity: Entity?

    @Published var isPlaced: Bool = false
}
