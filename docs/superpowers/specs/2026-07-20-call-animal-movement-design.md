# Call-Animal Movement (standalone RealityKit scaffold)

## Context

The original feature request ("Call Animal" button-triggered movement) was written
against RealityKit (`Entity`, `ModelEntity`, `AnchorEntity`, `ARView`) and assumed a
single already-placed, already-anchored animal.

Two existing codebases were checked against that assumption:

- `ARKitVision` (this repo) is actually built on **ARKit + SceneKit**
  (`ARSCNView`, `SCNNode`, `SCNAction`) — no RealityKit code exists here yet.
- The user's real app, `ARProject` (`/Users/riaatan/ARProject`), *is* RealityKit-based,
  but has a much richer architecture than the prompt assumed: a central `ARManager`
  (`ObservableObject`), multiple "spots" each with their own butterfly and an
  ambient `WanderController` that repositions the active butterfly on a repeating
  4-second `Timer`.

Decision: build this feature **independently, in this repo (`ARGrabMoveObject`),
separate from `ARProject`** — a small self-contained RealityKit scaffold that
doesn't touch `ARProject` and doesn't touch the existing SceneKit `ViewController`
code in this repo either. Because it's a standalone single-animal demo (no ambient
wander system to fight), the design is close to the original prompt's assumptions.

## Goal

A SwiftUI + RealityKit screen where:
1. Tapping a detected horizontal plane places `butterfly.usdz` (already present at
   `ARKitVision/Resources/butterfly.usdz`), which immediately starts looping its
   one baked wing-flap animation clip forever.
2. A "Call" button moves the placed butterfly from wherever it currently is to a
   point ~0.6m in front of the camera, on the same horizontal plane it was placed
   on, with a natural ease-in/ease-out turn-and-travel motion — not a teleport.
3. The movement is exposed as a single, clean entry point so a future
   gesture-detection trigger can call the exact same function the button calls.

## Non-goals

- Hand gesture / pose detection (Vision framework, ML) — a separate concern.
- Pathfinding, obstacle avoidance, or collision detection during the move.
- Idle/wander/follow behavior, or any trigger besides the button.
- Touching `ARProject` or the existing SceneKit `ViewController.swift` in this repo.
- Life-stage, feeding, or fact-tag systems.

## Architecture

New folder: `ARKitVision/RealityKitDemo/`. Existing SceneKit files (`ViewController.swift`,
`Main.storyboard`, etc.) remain in the project, untouched, just no longer launched.

### `DemoARManager.swift`
A small `ObservableObject` — the standalone equivalent of `ARProject`'s `ARManager`,
scoped down to what a single-animal demo needs:
```swift
class DemoARManager: ObservableObject {
    var cameraAnchor: AnchorEntity?
    var parentContainer: Entity = Entity()   // child of the plane anchor
    var animalEntity: Entity?
    @Published var isPlaced: Bool = false
}
```

### `AnimalCallScene.swift`
SwiftUI `RealityView`:
- Adds `AnchorEntity(.camera)` and `AnchorEntity(.plane(.horizontal, ...))`, matching
  the anchor setup pattern already proven in `ARProject`'s `ContentView`/`MainView`.
- `parentContainer` is added as a child of the plane anchor once it anchors.
- A tap gesture, only while `!isPlaced`: raycasts/places `butterfly.usdz` under
  `parentContainer` at the tapped point, then plays every available animation with
  `.repeat()` (mirrors `ARProject`'s `playAllAnimationsRecursive` pattern) and never
  stops it.
- A "Call" button overlay that calls `CallAnimalController.callAnimal(manager:)`.

### `CallAnimalController.swift`
```swift
class CallAnimalController {
    func callAnimal(manager: DemoARManager) { ... }
}
```
Steps:
1. Guard `animal = manager.animalEntity`, `camera = manager.cameraAnchor`.
2. Compute flattened camera-forward: `camera.orientation(relativeTo: nil).act([0,0,-1])`,
   zero out the Y component, normalize. This ignores device pitch so looking up/down
   doesn't send the target into the floor or ceiling.
3. `targetWorld = camera.position(relativeTo: nil) + flatForward * 0.6`.
4. Convert to local space: `targetLocal = manager.parentContainer.convert(position: targetWorld, from: nil)`,
   then override `targetLocal.y = animal.position.y` to keep the animal locked to
   the height/plane it was originally placed on.
5. If the horizontal distance from the animal's current local position to
   `targetLocal` is < 0.05m, return early (skip the pointless micro-turn).
6. `duration = clamp(distance / 0.5 /* m/s */, 0.6...3.0)`.
7. Facing rotation: `simd_quatf(from: [0, 0, 1], to: normalize(targetLocal - currentLocal))`
   — yaw-only by construction, since both points share the same Y.
8. Build a target `Transform` (translation + rotation, same scale) and call
   `animal.move(to: targetTransform, relativeTo: manager.parentContainer, duration: duration, timingFunction: .easeInOut)`.
9. No manual cancellation logic for repeat taps: RealityKit's `move(to:)` replaces
   an in-flight transform animation on the same entity when called again, so
   tapping "Call" again mid-move retargets cleanly with no stacking.
10. Debug `print` of computed distance and duration.
11. Skipped as a nice-to-have: vertical "bob" during travel (adds timing complexity
    for a cosmetic touch) and animation speed-up while traveling.

### Launch wiring
`AppDelegate.swift`: replace the body of `application(_:didFinishLaunchingWithOptions:)`
to build a `UIWindow` in code and set
`window.rootViewController = UIHostingController(rootView: AnimalCallScene())`,
`window.makeKeyAndVisible()` — bypassing `Main.storyboard`. Keep the existing
`ARWorldTrackingConfiguration.isSupported` guard. Nothing is deleted, so reverting
to the SceneKit demo later just means reverting this one file.

## Testing

No unit test suite fits AR/RealityKit movement code meaningfully in isolation
(it depends on live ARKit tracking state). Verification is manual, on-device:
place the butterfly, confirm it flutters continuously, tap "Call" from a few
different distances/angles (including looking up/down) and confirm natural
ease-in/out travel to ~0.6m in front of the camera, confirm re-tapping mid-move
retargets without stacking or jitter, confirm the animation never stops.
