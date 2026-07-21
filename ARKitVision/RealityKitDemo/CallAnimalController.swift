import RealityKit
import simd

// Integration contract:
// Call `CallAnimalController().callAnimal(manager:)` (or share one instance)
// from whatever triggers you want — a button action now, a gesture-recognizer
// callback later. Both call sites hit the exact same function, so wiring up a
// new trigger never requires touching this file.

/// Moves the currently-placed animal from wherever it is to a point ~0.6m in
/// front of the camera, on the plane it was placed on, with an eased
/// turn-and-travel motion instead of a teleport.
class CallAnimalController {

    /// Butterfly asset has exactly one baked animation (a continuous wing-flap
    /// loop) with no separate idle/flying clip, so this function never plays
    /// or stops animations — the loop keeps running underneath, started once
    /// at placement time and never touched again.
    func callAnimal(manager: ARManager) {
        guard let animal = manager.animalEntity,
              let camera = manager.cameraAnchor else { return }

        // Horizontal heading, robust to pitch. Deriving this from the forward
        // vector (zeroing its Y and renormalizing) breaks down as the device
        // tilts toward straight up/down: forward's horizontal component
        // shrinks toward zero there, so normalizing it amplifies noise and
        // the heading effectively stops tracking where you're actually
        // facing. The camera's *right* vector doesn't have this problem —
        // pitching (tilting up/down) rotates around that axis, so it stays
        // in the horizontal plane at any pitch. Rotating it 90 degrees
        // around world-up recovers a stable horizontal forward.
        let right3D = camera.orientation(relativeTo: nil).act(SIMD3<Float>(1, 0, 0))
        let flatForward = normalize(cross(SIMD3<Float>(0, 1, 0), SIMD3<Float>(right3D.x, 0, right3D.z)))

        let targetWorld = camera.position(relativeTo: nil) + flatForward * 0.6

        // Convert into parentContainer's local space, since that's the space
        // this entity's transform is expressed in (it's a child of the plane
        // anchor via parentContainer, not directly anchored in world space).
        var targetLocal = manager.parentContainer.convert(position: targetWorld, from: nil)

        // Keep the animal locked to the height/plane it was originally placed
        // on — only its X/Z changes, never its Y.
        let currentLocal = animal.position(relativeTo: manager.parentContainer)
        targetLocal.y = currentLocal.y

        let delta = targetLocal - currentLocal
        let distance = simd_length(SIMD2<Float>(delta.x, delta.z))

        // Skip the whole move for a pointless micro-turn.
        guard distance > 0.05 else { return }

        let speed: Float = 0.5 // m/s, within the suggested 0.4-0.6 range
        let duration = Double(min(max(distance / speed, 0.6), 3.0))

        // Face the camera at the destination, not the direction of travel.
        // Facing travel direction looks right for a straight, mostly-forward
        // first call, but on a repeat call from nearby the hop to the new
        // spot is often short and sideways relative to the user — facing
        // *that* leaves the animal looking side-on instead of at the user.
        // A called animal should end up looking at whoever called it,
        // regardless of the path it took to get there.
        let cameraLocal = manager.parentContainer.convert(position: camera.position(relativeTo: nil), from: nil)
        let towardCamera = normalize(SIMD3<Float>(cameraLocal.x - targetLocal.x, 0, cameraLocal.z - targetLocal.z))

        // Yaw-only "for free": both vectors have zero Y. This asset's modeled
        // forward axis is +Z (matches how its wander/idle rotations are
        // computed elsewhere), not RealityKit's default -Z.
        let facing = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: towardCamera)

        var targetTransform = animal.transform
        targetTransform.translation = targetLocal
        targetTransform.rotation = facing

        // No manual cancellation needed for a repeated tap mid-move: RealityKit
        // replaces an in-flight transform animation on the same entity when
        // move(to:) is called again, so this cleanly retargets rather than
        // stacking animations.
        animal.move(to: targetTransform, relativeTo: manager.parentContainer, duration: duration, timingFunction: .easeInOut)

        print("callAnimal: distance=\(distance)m duration=\(duration)s")
    }
}
