import Foundation
import ARKit
import RealityKit
import SwiftUI

@available(iOS 14.0, *)
extension ARManager {
    
    // MARK: - Hand Interaction Logic
    
    func handleHandInteraction(isGrabbing: Bool, normalizedPinchMidpoint: CGPoint?) {
        guard currentMode == .interact else {
            wasGrabbing = isGrabbing
            cursorEntity?.isEnabled = false
            return
        }
        
        guard let pinchMid = normalizedPinchMidpoint, let frame = arView?.session.currentFrame, let arView = arView else {
            if !isGrabbing && wasGrabbing {
                releaseGrabbedObject()
            }
            wasGrabbing = isGrabbing
            cursorEntity?.isEnabled = false
            return
        }
        
        let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.interfaceOrientation ?? .portrait
        let transform = frame.displayTransform(for: orientation, viewportSize: arView.bounds.size)
        let invertedYPoint = CGPoint(x: pinchMid.x, y: 1.0 - pinchMid.y)
        let viewportNormalized = invertedYPoint.applying(transform)
        let screenPoint = CGPoint(x: viewportNormalized.x * arView.bounds.width,
                                  y: viewportNormalized.y * arView.bounds.height)
        
        var currentHandPosition: SIMD3<Float>?
        var isHovering = false
        var closestNodeToGrab: Entity?
        
        if let depth = getDepth(at: screenPoint, in: frame) {
            currentHandPosition = unproject(screenPoint: screenPoint, depth: depth, in: arView)
        } else {
            // LiDAR blindspot fallback
            currentHandPosition = unproject(screenPoint: screenPoint, depth: 0.3, in: arView)
        }
        
        if let handPos = currentHandPosition {
            if cursorEntity == nil {
                let sphere = ModelEntity(mesh: .generateSphere(radius: 0.02), materials: [SimpleMaterial(color: .yellow, isMetallic: false)])
                let cursorAnchor = AnchorEntity(world: .zero)
                cursorAnchor.addChild(sphere)
                arView.scene.addAnchor(cursorAnchor)
                self.cursorEntity = sphere
            }
            cursorEntity?.isEnabled = true
            cursorEntity?.position = handPos
            
            // Check for Hovering over an Apple
            var closestDistance: Float = .infinity
            
            // Iterate through root anchors to find Apples (we label them with name "Apple")
            for anchor in arView.scene.anchors {
                for entity in anchor.children {
                    if entity.name == "Apple" {
                        let nodePos = entity.position(relativeTo: nil)
                        let dx = nodePos.x - handPos.x
                        let dy = nodePos.y - handPos.y
                        let dz = nodePos.z - handPos.z
                        
                        let visualDistance = hypot(dx, dy)
                        let depthDistance = abs(dz)
                        
                        if visualDistance < 0.09 && depthDistance < 0.15 {
                            isHovering = true
                            if visualDistance < closestDistance {
                                closestDistance = visualDistance
                                closestNodeToGrab = entity
                            }
                        }
                    }
                }
            }
            
            if isHovering {
                cursorEntity?.model?.materials = [SimpleMaterial(color: .green, isMetallic: false)]
            } else if getDepth(at: screenPoint, in: frame) == nil {
                cursorEntity?.model?.materials = [SimpleMaterial(color: .red, isMetallic: false)]
            } else {
                cursorEntity?.model?.materials = [SimpleMaterial(color: .yellow, isMetallic: false)]
            }
        }
        
        if isGrabbing && !wasGrabbing {
            // Started grabbing
            if let targetEntity = closestNodeToGrab {
                draggedAppleEntity = targetEntity
                // Re-parent to cursor to drag it naturally
                if let cursor = cursorEntity {
                    let worldTransform = targetEntity.transformMatrix(relativeTo: nil)
                    targetEntity.setParent(cursor)
                    targetEntity.setTransformMatrix(worldTransform, relativeTo: nil)
                }
            }
        } else if !isGrabbing && wasGrabbing {
            // Dropped
            releaseGrabbedObject()
        }
        
        wasGrabbing = isGrabbing
        
        if isGrabbing, let apple = draggedAppleEntity {
            updateButterflyFlight(for: apple)
        }
    }
    
    func releaseGrabbedObject() {
        if let draggedNode = draggedAppleEntity {
            draggedNode.removeFromParent()
            self.draggedAppleEntity = nil

            // Alert user (best done via publishing state, or direct UI Window access for simplicity here)
            DispatchQueue.main.async {
                if let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                   let window = windowScene.windows.first {
                    let alert = UIAlertController(title: "Yum!", message: "You ate the Apple!", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Delicious", style: .default, handler: nil))
                    window.rootViewController?.present(alert, animated: true)
                }
            }
        }
    }
    
    func updateButterflyFlight(for apple: Entity, speed: Float = 0.1) {
        guard let butterfly = animalEntity, let camera = cameraAnchor else { return }
        
        let cameraPos = camera.position(relativeTo: nil)
        let applePos = apple.position(relativeTo: nil)
        
        // Direction from camera to apple
        let direction = normalize(applePos - cameraPos)
        
        // Target is 5cm behind the apple (further from camera)
        let targetPos = applePos + (direction * 0.05)
        
        let currentPos = butterfly.position(relativeTo: nil)
        // Smoothly interpolate position for continuous flight
        let newPos = currentPos + (targetPos - currentPos) * speed
        
        butterfly.setPosition(newPos, relativeTo: nil)
        
        // RealityKit's look(at:) points -Z at the target.
        // The butterfly asset's forward is +Z, so we rotate 180 degrees around Y.
        butterfly.look(at: applePos, from: newPos, relativeTo: nil)
        butterfly.transform.rotation *= simd_quatf(angle: .pi, axis: [0, 1, 0])
    }
    
    // MARK: - Spawning Logic
    
    func handleTap(at screenLocation: CGPoint) {
        guard arView != nil else { return }
        
        if currentMode == .interact {
            spawnApple()
        }
    }
    
    func spawnApple() {
        guard let arView = arView, let frame = arView.session.currentFrame else { return }
        
        var translation = matrix_identity_float4x4
        translation.columns.3.z = -0.6 // 0.6m in front
        let anchorTransform = simd_mul(frame.camera.transform, translation)
        
        let anchor = AnchorEntity(world: anchorTransform)
        arView.scene.addAnchor(anchor)
        
        // Load the Apple USDZ
        Task { @MainActor in
            do {
                let apple = try await ModelEntity(named: "Apple")
                
                // Scale it to ~15cm (0.15m) using its bounding box
                let bounds = apple.visualBounds(relativeTo: apple)
                let width = bounds.extents.x
                if width > 0 {
                    let scale = 0.15 / width
                    apple.scale = SIMD3<Float>(repeating: scale)
                }
                
                apple.name = "Apple"
                
                // Visual buffer cylinder
                let cylinderMesh = MeshResource.generateCylinder(height: 0.30, radius: 0.09)
                let cylinderMaterial = SimpleMaterial(color: .cyan.withAlphaComponent(0.4), isMetallic: false)
                let cylinder = ModelEntity(mesh: cylinderMesh, materials: [cylinderMaterial])
                cylinder.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
                
                apple.addChild(cylinder)
                
                DispatchQueue.main.async {
                    anchor.addChild(apple)
                }
            } catch {
                print("Failed to load Apple: \(error)")
                // Fallback red sphere
                let sphere = ModelEntity(mesh: .generateSphere(radius: 0.06), materials: [SimpleMaterial(color: .red, isMetallic: false)])
                sphere.name = "Apple"
                DispatchQueue.main.async {
                    anchor.addChild(sphere)
                }
            }
        }
    }
}
