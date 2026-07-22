import SwiftUI
import RealityKit

/// Standalone scaffold: tap a detected floor to place the butterfly, then tap
/// "Call" to bring it to a point in front of the camera. Independent of the
/// existing SceneKit ViewController in this project.
    struct AnimalCallScene: View {
        @ObservedObject var manager: ARManager

        @State private var isSpawning = false
    
        var body: some View {
            ZStack {
                // The shared ARViewContainer is in ContentView. We just provide a full-screen tap target.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        placeButterflyIfNeeded()
                    }
                    .edgesIgnoringSafeArea(.all)


            VStack {
                Spacer()
                if !manager.isPlaced {
                    Text("Tap the floor to place the butterfly")
                        .padding()
                        .background(.thinMaterial, in: Capsule())
                }
            }
            .padding(.bottom, 50)
        }
    }

    /// Ray-plane intersection using the camera's forward direction, the same
    /// technique used elsewhere for tap-to-place: place at whatever point on
    /// the plane the user is currently looking toward, regardless of exact
    /// screen tap coordinates.
    private func placeButterflyIfNeeded() {
        guard !manager.isPlaced, !isSpawning,
              let camAnchor = manager.cameraAnchor,
              let planeAnchor = manager.parentContainer.parent as? AnchorEntity,
              planeAnchor.isAnchored else { return }

        let planeHeight = planeAnchor.position(relativeTo: nil).y
        let camPos = camAnchor.position(relativeTo: nil)
        let forward = camAnchor.orientation(relativeTo: nil).act(SIMD3<Float>(0, 0, -1))

        guard forward.y < -0.1 else { return }
        let t = (planeHeight - camPos.y) / forward.y
        guard t > 0 else { return }

        let intersectionWorld = camPos + t * forward
        let localPos = planeAnchor.convert(position: intersectionWorld, from: nil)
        manager.parentContainer.position = [localPos.x, 0, localPos.z]

        // Spawn height as a fraction of the camera's height above the floor
        // at this moment, instead of one fixed number for everyone — scales
        // naturally to whoever is placing it (a kid's hand height vs an
        // adult's), same reasoning as the tilt-responsive call height.
        // Clamped so an unusually high/low hold still gives a sane result.
        let cameraHeightAboveFloor = camPos.y - planeHeight
        let spawnHeight = min(max(cameraHeightAboveFloor * 0.3, 0.2), 0.6)

        isSpawning = true
        Task { @MainActor in
            defer { isSpawning = false }
            do {
                let butterfly = try await Entity(named: "butterfly", in: nil)
                butterfly.scale = SIMD3<Float>(repeating: 0.001)
                butterfly.position = [0, spawnHeight, 0]
                manager.parentContainer.addChild(butterfly)

                for animation in butterfly.availableAnimations {
                    butterfly.playAnimation(animation.repeat())
                }

                manager.animalEntity = butterfly
                manager.isPlaced = true
            } catch {
                print("Failed to load butterfly.usdz: \(error)")
            }
        }
    }
}

#Preview {
    AnimalCallScene(manager: ARManager())
}
