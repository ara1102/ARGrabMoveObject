# Feeding (Pinch-to-Feed Animal)

## Context

The app currently has three modes in `AppMode` (`Debug`, `Interact`, `Animal Call`),
switched via a segmented picker in `ContentView`:

- **Animal Call**: `AnimalCallScene` lets the user tap a detected floor to place
  `butterfly.usdz` under `ARManager.parentContainer`. A held hand-curl gesture
  (`HandCurlCallController`, gated to `currentMode == .animalCall`) triggers
  `CallAnimalController.callAnimal(manager:)`, which eases the placed animal to a
  point in front of the camera.
- **Interact**: tapping spawns an `Apple` entity 0.6m in front of the camera.
  A thumb-index pinch (computed unconditionally every frame in
  `ARManager.processHandPose`, but only *acted on* when `currentMode == .interact`)
  lets the user grab and drag the nearest `Apple` by re-parenting it to a cursor
  entity. Releasing shows a placeholder `UIAlertController` ("Yum! You ate the
  Apple!") and removes the apple.
- `bugEating.mp3` was recently added to `Resources/` but nothing plays it yet.

These two mechanics (call vs. grab) are unconnected: the animal never reacts to
the Apple, and the pinch/grab logic only exists inside Interact mode where no
animal is present. This spec adds a **new, separate mode** — Feeding — rather
than merging Interact or Animal Call, so curl-to-call and pinch-to-feed stay two
distinct, non-conflicting gestures, each with its own screen.

## Goal

A new `Feeding` mode where:

1. Entering the mode requires an animal already placed via Animal Call mode
   (`manager.isPlaced`). If none exists yet, show a message instead of spawning
   anything.
2. One food entity spawns automatically at a random reachable point (random
   angle/distance in front of the camera, within pinch/hover range) when the
   mode is entered.
3. Pinching the food immediately starts the animal walking toward a point in
   front of the camera (reusing `CallAnimalController`'s movement math).
4. The pinch must stay held continuously until eating finishes. Releasing early
   at any point cancels the whole sequence with **no** side effect — no sound,
   no banner, no food removal; the animal simply stays wherever it currently is.
5. Once the animal arrives *and* the food is still held, play `bugEating.mp3`
   once (~1.4s, its natural length — no separate duration constant needed).
6. If the food is still held when the sound finishes, remove the food entity
   and show a transient, non-blocking success banner.

## Non-goals

- Changing curl-to-call: stays exclusively gated to Animal Call mode, untouched.
- Multiple simultaneous food items or an auto-repeating feed loop — MVP is one
  food entity per mode-entry.
- Animal walking to the food's literal world position — MVP reuses the existing
  camera-forward call target (food is assumed to be held close to the user).
- Pathfinding/obstacle avoidance, or reverting the animal's position on cancel.
- Feeding history/stats persistence.

## Architecture

### `AppMode.swift`
Add `case feeding = "Feeding"` to the enum, alongside the existing cases.

### `FeedingController.swift` (new)
Same ownership pattern as `CallAnimalController`/`HandCurlCallController`: a
plain class instantiated once and held by `ARManager`, with a small state
machine (`idle`, `walking`, `eating`) plus a reference to the currently-spawned
food entity.

```swift
class FeedingController {
    private enum State { case idle, walking(arrivesAt: Date), eating(endsAt: Date) }
    private var state: State = .idle
    private var audioPlayer: AVAudioPlayer?

    func spawnFood(manager: ARManager) { ... }
    func update(manager: ARManager, isGrabbing: Bool, normalizedPinchMidpoint: CGPoint?) { ... }
}
```

- **`spawnFood(manager:)`**: called once when `FeedingScene` appears (guarded so
  it only runs if no food is currently active). Picks a random angle
  (0...2π) and random distance (0.3–0.6m, same order of magnitude as the
  existing apple-spawn/call-distance ranges) from the camera, reuses the same
  raycast/anchor pattern as `spawnApple()`, loads the existing `Apple.usdz` as
  the food model, and names the entity `"Food"` (distinct from Interact mode's
  `"Apple"` so the two pinch flows never hit-test each other's entities).

- **`update(...)`**: called every frame from `ARManager` while
  `currentMode == .feeding`, fed the same `isGrabbing` / `normalizedPinchMidpoint`
  values already computed each frame for Interact mode's grab logic.
  - `.idle`: hit-tests the hand position against the `"Food"` entity using the
    same hover thresholds already used for Apple (`visualDistance < 0.09 &&
    depthDistance < 0.15`). On a fresh pinch engagement while hovering food,
    calls `CallAnimalController.callAnimal(manager:)` and transitions to
    `.walking(arrivesAt: now + duration)`.
  - `.walking`: if `isGrabbing` goes false before `arrivesAt`, cancel back to
    `.idle` (no other effect). Once `arrivesAt` passes while still grabbing,
    play `bugEating.mp3` via `AVAudioPlayer` and transition to
    `.eating(endsAt: now + player.duration)`.
  - `.eating`: if `isGrabbing` goes false before `endsAt`, stop the player and
    cancel back to `.idle` (food is **not** removed). If still grabbing when
    `endsAt` passes, remove the food entity, set
    `manager.feedingSuccessMessage` (auto-cleared after ~1.5s), and reset to
    `.idle`.

### `CallAnimalController.swift`
Change the signature to return the computed travel duration so `FeedingController`
can schedule the arrival check:
`@discardableResult func callAnimal(manager: ARManager) -> TimeInterval?`
(`nil` when the existing "pointless micro-turn" early-return fires — treated by
the caller as "already there".)

### `ARManager.swift`
- Add `private let feedingController = FeedingController()`.
- Add `@Published var feedingSuccessMessage: String?`.
- In `processHandPose`'s main-thread block, alongside the existing
  `handleHandInteraction(...)` call, add:
  ```swift
  if self.currentMode == .feeding {
      self.feedingController.update(manager: self, isGrabbing: currentPinchState, normalizedPinchMidpoint: normalizedPinchMidpoint)
  }
  ```

### `FeedingScene.swift` (new)
SwiftUI view, structured like `AnimalCallScene`:
- On appear: if `!manager.isPlaced`, show "Taruh hewan dulu di mode Animal Call"
  and stop — no food spawn.
- Otherwise call `feedingController.spawnFood(manager:)` once.
- A capsule banner (same `.thinMaterial` style already used for the "Tap the
  floor..." hint) bound to `manager.feedingSuccessMessage`, fading in/out
  automatically — no manual dismiss.

### `ContentView.swift`
Add a `Feeding` branch next to the existing `.animalCall` one:
```swift
if arManager.currentMode == .feeding {
    FeedingScene(manager: arManager)
}
```

## Testing

No unit test suite meaningfully covers live ARKit tracking/gesture state (same
as the existing Call-Animal spec). Manual on-device verification:

- Place and call the animal in Animal Call mode, switch to Feeding mode, confirm
  food spawns at a random reachable point.
- Pinch the food, confirm the animal starts walking; release mid-walk and
  confirm it cancels silently (no sound/banner) with the animal staying put.
- Pinch and hold through arrival, confirm the eating sound plays once.
- Release during the eating sound, confirm it cancels — food is **not** removed,
  no banner shown.
- Hold through the full sequence, confirm the food is removed and the success
  banner appears then fades automatically.
- Confirm curl-to-call still only works in Animal Call mode, unaffected.
- Switch to Feeding mode without ever placing an animal, confirm the message is
  shown instead of a crash.
