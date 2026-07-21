# Migration Guide: Legacy Architecture to SwiftUI & RealityKit

This document outlines the architectural changes made during the migration of this project. The application was successfully modernized from a legacy `UIKit` and `SceneKit` foundation to a robust, reactive architecture powered by `SwiftUI` and `RealityKit`.

## 1. UI Layer: UIKit ➔ SwiftUI

The original app relied heavily on an imperative, storyboard-driven UI. We completely replaced this with a declarative SwiftUI architecture.

### Before (UIKit)
* **View Hierarchy**: Managed via `Main.storyboard`, requiring IBOutlet connections and manual constraint management.
* **Entry Point**: `AppDelegate` loaded the `ViewController` implicitly from the storyboard.
* **State Management**: Highly imperative. When the tracking state changed or a mode was switched, `ViewController.swift` had to manually update `UILabel.text` and manage visibility of layers.
* **Event Handling**: Tap gestures were managed by attaching a `UITapGestureRecognizer` to the `ARSCNView`, parsing segmented control indices to determine behavior.

### After (SwiftUI)
* **View Hierarchy**: Built using `ContentView.swift`. The UI is composed using declarative stacks (`ZStack`, `VStack`).
* **Entry Point**: `AppDelegate.swift` uses a `UIHostingController` to inject `ContentView` as the root view.
* **State Management**: Reactive and data-driven via `Combine`. We introduced an `ObservableObject` called `ARManager`. When `ARManager` updates an `@Published` property (like `trackingStateMessage`), `ContentView` automatically re-renders the changes instantly.
* **Event Handling**: Handled natively using SwiftUI's `.onTapGesture` modifier on the view, routing clean commands to the `ARManager`.

---

## 2. AR Engine: SceneKit ➔ RealityKit

`SceneKit` was originally designed as a general-purpose 3D rendering engine and later adapted for ARKit. `RealityKit` was built by Apple exclusively for Augmented Reality, offering built-in physics, highly performant ECS (Entity-Component-System) architecture, and vastly improved rendering.

### Before (SceneKit)
* **Core View**: `ARSCNView` managed the visual output.
* **Base Objects**: Everything in the 3D scene was an `SCNNode`. Adding objects required fetching the `scene.rootNode` and appending clones of parsed `.scn` or `.dae` files.
* **Coordinate Mapping**: To draw 2D debug circles (Debug Mode), the app relied on SceneKit's `projectPoint` API or custom UIKit overlays layered over the camera.
* **Movement**: Used explicit `SCNAction` objects or manually updated `SCNNode.position` inside the render loop.

### After (RealityKit)
* **Core View**: `ARView` manages the AR session. We wrap it in a `UIViewRepresentable` called `ARViewContainer` to bridge it into SwiftUI.
* **Base Objects**: Replaced `SCNNode` with **Entities**. 
  - `AnchorEntity`: Used to lock digital content to physical constructs (e.g., the `.camera`, or a detected horizontal `.plane`).
  - `ModelEntity`: Used to hold 3D meshes and materials (e.g., the Apple, the 3D cursor, the Butterfly).
* **Asset Loading**: RealityKit natively supports and prefers `.usdz` files. Spawning the Apple is now handled asynchronously via `ModelEntity(named: "Apple")`.
* **Coordinate Mapping (Math)**: In Debug Mode, to overlay 2D circles, we now use `ARFrame.displayTransform` to perfectly un-project the Vision framework's landscape coordinate buffer into the portrait SwiftUI viewport. In Interact Mode, we use LiDAR depth mapping (`ARFrame.sceneDepth`) combined with camera ray-casting (`arView.ray(through:)`) to construct a highly accurate 3D `SIMD3<Float>` position for the cursor.
* **Movement**: Animated translation (such as the butterfly flying to the camera in Animal Call Mode) is handled simply by invoking `entity.move(to: transform, duration: 2.0)`, which handles interpolation naturally.

---

## 3. Structural Organization (MVVM)

The project structure was flattened into a clean MVVM pattern:

* **`Models/`**: Contains pure data structures (e.g., `AppMode.swift`).
* **`Views/`**: Contains the SwiftUI presentations (`ContentView.swift`, `ARViewContainer.swift`, and RealityKit scaffolds like `AnimalCallScene.swift`).
* **`Controllers/`**: Houses the business logic. `ARManager.swift` acts as the single source of truth for the AR session, LiDAR queries, and Vision processing.
* **`DeadCode/`**: Contains deprecated UIKit artifacts (`ViewController.swift`, `Main.storyboard`) kept strictly for historical reference.

---

## 4. API Modernization & Requirements

During the migration, several legacy iOS APIs were modernized to adhere to current best practices, resulting in a required minimum deployment target of **iOS 15.0**.

* **Swift Concurrency**: Asynchronous operations, specifically the loading of RealityKit `.usdz` assets, were migrated to use modern Swift Concurrency (`Task` and `try await ModelEntity(named:)`). This is a massive improvement over older completion handler blocks but strictly requires iOS 15.0.
* **Window Management**: References to `UIApplication.shared.windows` (which was deprecated in iOS 15) were replaced. The app now properly queries the connected `UIWindowScene` to handle multi-window environments and retrieve accurate interface orientations.
* **Vision Framework**: Removed deprecated properties like `usesCPUOnly` in favor of allowing the OS to optimize utilizing the Neural Engine dynamically.
