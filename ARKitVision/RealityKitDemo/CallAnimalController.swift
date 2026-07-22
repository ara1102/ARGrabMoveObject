import Foundation
import RealityKit
import simd

// Integration contract:
// Call `CallAnimalController().callAnimal(manager:)` (or share one instance)
// from whatever triggers you want — a button action, a gesture-recognizer
// callback, a feeding drop event. Every call site hits the exact same
// function and gets the same result, so wiring up a new trigger never
// requires touching this file.

/// Moves the currently-placed animal from wherever it is to a point in front
/// of the camera, on the plane it was placed on, with an eased
/// turn-and-travel motion instead of a teleport.
class CallAnimalController {

    /// Low end of the tilt-responsive height below: how close to the floor
    /// the animal comes when you look straight down. The HIGH end isn't a
    /// fixed number — it's "wherever the camera currently is," confirmed
    /// correct on-device: moving the device to a different physical height
    /// already moves the animal to match. Anchoring to the camera's live
    /// height instead of a fixed "flying height" constant means this scales
    /// naturally to whoever's holding the device (a kid's hand height vs an
    /// adult's), instead of assuming one height for everyone.
    private let groundHoverHeight: Float = 0.05

    /// Butterfly asset has exactly one baked animation (a continuous wing-flap
    /// loop) with no separate idle/flying clip, so this function never plays
    /// or stops animations — the loop keeps running underneath, started once
    /// at placement time and never touched again.
    func callAnimal(manager: ARManager) {
        guard let animal = manager.animalEntity,
              let camera = manager.cameraAnchor else { return }

        // Yaw-only heading for DIRECTION, robust to pitch. Deriving this from
        // the forward vector (zeroing its Y and renormalizing) breaks down as
        // the device tilts toward straight up/down: forward's horizontal
        // component shrinks toward zero there, so normalizing it amplifies
        // noise and the heading effectively stops tracking where you're
        // actually facing. The camera's *right* vector doesn't have this
        // problem — pitching (tilting up/down) rotates around that axis, so
        // it stays in the horizontal plane at any pitch. Rotating it 90
        // degrees around world-up recovers a stable horizontal forward.
        let right3D = camera.orientation(relativeTo: nil).act(SIMD3<Float>(1, 0, 0))
        let flatForward = normalize(cross(SIMD3<Float>(0, 1, 0), SIMD3<Float>(right3D.x, 0, right3D.z)))

        // Tilt-responsive DISTANCE: look down more -> the animal appears
        // closer (toward your feet), stay level or look up -> a comfortable
        // default distance. Confirmed the camera-height baseline works
        // on-device, so re-enabling this on top of it.
        let trueForward = camera.orientation(relativeTo: nil).act(SIMD3<Float>(0, 0, -1))
        let downTilt = max(0, -trueForward.y) // 0 = level or looking up, 1 = straight down
        let minDistance: Float = 0.2
        let maxDistance: Float = 0.9
        let distanceFromCamera = maxDistance - (maxDistance - minDistance) * downTilt

        let targetWorld = camera.position(relativeTo: nil) + flatForward * distanceFromCamera

        // Convert into parentContainer's local space, since that's the space
        // this entity's transform is expressed in (it's a child of the plane
        // anchor via parentContainer, not directly anchored in world space).
        var targetLocal = manager.parentContainer.convert(position: targetWorld, from: nil)

        // Tilt-responsive HEIGHT: blend from the camera's OWN current height
        // (targetLocal.y already carries this, straight from the conversion
        // above, since flatForward has no vertical component) down toward
        // the floor as you tilt further down. Confirmed on-device that
        // physical device height already sets this baseline correctly, so
        // this only adds the *extra* downward pull from tilt on top of it.
        let cameraHeightLocal = targetLocal.y
        targetLocal.y = cameraHeightLocal - (cameraHeightLocal - groundHoverHeight) * downTilt

        let currentLocal = animal.position(relativeTo: manager.parentContainer)

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

        print("callAnimal: distance=\(distance)m duration=\(duration)s tilt=\(downTilt) targetY=\(targetLocal.y)")
    }

    /// Moves the animal to a point directly behind the food relative to the camera,
    /// elevated slightly so it appears to peak over the food.
    @discardableResult
    func callAnimalToFood(manager: ARManager, foodEntity: Entity) -> TimeInterval? {
        guard let animal = manager.animalEntity,
              let camera = manager.cameraAnchor else { return nil }

        let cameraWorldPos = camera.position(relativeTo: nil)
        let foodWorldPos = foodEntity.position(relativeTo: nil)

        // Flatten positions to find the horizontal line (ignore height/Y)
        let cameraFlatPos = SIMD3<Float>(cameraWorldPos.x, 0, cameraWorldPos.z)
        let foodFlatPos = SIMD3<Float>(foodWorldPos.x, 0, foodWorldPos.z)

        let flatVector = foodFlatPos - cameraFlatPos
        let length = simd_length(flatVector)
        let flatDirection = length > 0.001 ? (flatVector / length) : SIMD3<Float>(0, 0, -1)

        let depthBuffer: Float = 0.15  // 15cm further back (behind the apple)
        let heightBuffer: Float = 0.10 // 10cm higher than the apple

        var targetWorldPos = foodWorldPos + (flatDirection * depthBuffer)
        targetWorldPos.y += heightBuffer

        let targetLocal = manager.parentContainer.convert(position: targetWorldPos, from: nil)
        let currentLocal = animal.position(relativeTo: manager.parentContainer)
        
        let delta = targetLocal - currentLocal
        let distance = simd_length(SIMD2<Float>(delta.x, delta.z))

        // Skip the whole move for a pointless micro-turn.
        guard distance > 0.05 else { return nil }

        let speed: Float = 0.5 // m/s
        let duration = Double(min(max(distance / speed, 0.6), 3.0))

        // Face the camera at the destination
        let cameraLocal = manager.parentContainer.convert(position: cameraWorldPos, from: nil)
        let towardCamera = normalize(SIMD3<Float>(cameraLocal.x - targetLocal.x, 0, cameraLocal.z - targetLocal.z))
        let facing = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: towardCamera)

        var targetTransform = animal.transform
        targetTransform.translation = targetLocal
        targetTransform.rotation = facing

        animal.move(to: targetTransform, relativeTo: manager.parentContainer, duration: duration, timingFunction: .easeInOut)

        print("callAnimalToFood: distance=\(distance)m duration=\(duration)s targetY=\(targetLocal.y)")
        return duration
    }
}
