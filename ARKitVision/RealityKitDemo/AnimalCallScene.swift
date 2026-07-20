import SwiftUI
import RealityKit

/// Standalone scaffold: tap a detected floor to place the butterfly, then tap
/// "Call" to bring it to a point in front of the camera. Independent of the
/// existing SceneKit ViewController in this project.
struct AnimalCallScene: View {
    @StateObject private var manager = DemoARManager()
    private let callAnimalController = CallAnimalController()

    @State private var isSpawning = false

    var body: some View {
        ZStack {
            RealityView { content in
                let camAnchor = AnchorEntity(.camera)
                content.add(camAnchor)
                manager.cameraAnchor = camAnchor

                let planeAnchor = AnchorEntity(.plane(.horizontal, classification: .any, minimumBounds: SIMD2<Float>(0.2, 0.2)))
                planeAnchor.addChild(manager.parentContainer)
                content.add(planeAnchor)

                content.camera = .spatialTracking
            }
            .onTapGesture {
                placeButterflyIfNeeded()
            }
            .edgesIgnoringSafeArea(.all)

            VStack {
                Spacer()
                if manager.isPlaced {
                    // DEV-ONLY TRIGGER: stands in for the real gesture-based
                    // call trigger a teammate is building separately. Not
                    // final UI — deliberately unstyled/undesigned so it's
                    // obvious this is scaffolding, not something to polish or
                    // ship. Swap this button out for the real trigger; leave
                    // `callAnimalController.callAnimal(manager:)` as-is.
                    Button("DEV: Call") {
                        callAnimalController.callAnimal(manager: manager)
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 14)
                    .background(Color.yellow.opacity(0.9), in: Capsule())
                    .foregroundColor(.black)
                } else {
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

        isSpawning = true
        Task {
            defer { isSpawning = false }
            do {
                let butterfly = try await Entity(named: "butterfly", in: nil)
                butterfly.scale = SIMD3<Float>(repeating: 0.001)
                butterfly.position = [0, 0.35, 0]
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
    AnimalCallScene()
}
