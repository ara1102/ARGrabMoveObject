import Foundation
import ARKit
import RealityKit
import AVFoundation
import SwiftUI

class FeedingController {
    
    private var audioPlayer: AVAudioPlayer?
    private var foodEntities: [Entity] = []
    private var foodAnchors: [AnchorEntity] = []
    private var cursorEntity: ModelEntity?
    private var draggedFoodEntity: Entity?
    private var wasGrabbing: Bool = false
    private var eatingStartedAt: Date?
    
    // Exposed variable so you can adjust how fast the butterfly catches the flower
    // Default is 0.1, lower is slower!
    var butterflySpeed: Float = 0.05
    
    private let callAnimalController = CallAnimalController()
    
    init() {
        if let url = Bundle.main.url(forResource: "bugEating", withExtension: "mp3") {
            audioPlayer = try? AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            audioPlayer?.numberOfLoops = -1 // Loop indefinitely while eating
        }
    }
    
    func spawnFood(manager: ARManager) {
        guard foodEntities.isEmpty else { return } // Only spawn if empty
        
        // Clean up old pillar anchors before spawning new ones
        for anchor in foodAnchors {
            anchor.removeFromParent()
        }
        foodAnchors.removeAll()
        
        guard let arView = manager.arView, let camera = manager.cameraAnchor else { return }
        
        let floorHeight = manager.parentContainer.position(relativeTo: nil).y
        let cameraHeight = camera.position(relativeTo: nil).y
        let targetHeight = floorHeight + (cameraHeight - floorHeight) * (2.0 / 3.0)
        let pillarHeight = targetHeight - floorHeight
        
        let forward = camera.orientation(relativeTo: nil).act(SIMD3<Float>(0, 0, -1))
        let flatForward = normalize(SIMD3<Float>(forward.x, 0, forward.z))
        
        let angles: [Float] = [-(.pi / 8), (.pi / 8)]
        let distance: Float = 1.0
        
        Task { @MainActor in
            for angle in angles {
                let rotation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
                let direction = rotation.act(flatForward)
                
                var targetPosition = camera.position(relativeTo: nil) + direction * distance
                targetPosition.y = targetHeight
                
                let anchor = AnchorEntity(world: targetPosition)
                arView.scene.addAnchor(anchor)
                self.foodAnchors.append(anchor)
                
                do {
                    let food = try await ModelEntity(named: "flower_food")
                    
                    let bounds = food.visualBounds(relativeTo: food)
                    let width = max(bounds.extents.x, bounds.extents.z)
                    if width > 0 {
                        let scale = 0.25 / width
                        food.scale = SIMD3<Float>(repeating: scale)
                    }
                    
                    food.name = "FeedingFood" 
                    
                    if pillarHeight > 0 {
                        let cylinderMesh = MeshResource.generateCylinder(height: pillarHeight, radius: 0.10)
                        let cylinderMaterial = SimpleMaterial(color: .white, isMetallic: false)
                        let cylinder = ModelEntity(mesh: cylinderMesh, materials: [cylinderMaterial])
                        cylinder.position.y = -(pillarHeight / 2)
                        anchor.addChild(cylinder)
                    }
                    
                    let triggerMesh = MeshResource.generateSphere(radius: 0.15)
                    let triggerMaterial = SimpleMaterial(color: .white.withAlphaComponent(0.0), isMetallic: false)
                    let trigger = ModelEntity(mesh: triggerMesh, materials: [triggerMaterial])
                    
                    food.addChild(trigger)
                    
                    self.foodEntities.append(food)
                    anchor.addChild(food)
                    
                } catch {
                    print("Failed to load flower_food: \(error)")
                    let fallback = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [SimpleMaterial(color: .purple, isMetallic: false)])
                    fallback.name = "FeedingFood"
                    self.foodEntities.append(fallback)
                    anchor.addChild(fallback)
                }
            }
        }
    }
    
    func update(manager: ARManager, isGrabbing: Bool, normalizedPinchMidpoint: CGPoint?) {
        guard let pinchMid = normalizedPinchMidpoint, let arView = manager.arView, let frame = arView.session.currentFrame else {
            if !isGrabbing && wasGrabbing {
                dropGrabbedFood(manager: manager)
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
        if let depth = getDepth(at: screenPoint, in: frame, arView: arView) {
            if let ray = arView.ray(through: screenPoint) {
                currentHandPosition = ray.origin + ray.direction * depth
            }
        } else {
            if let ray = arView.ray(through: screenPoint) {
                currentHandPosition = ray.origin + ray.direction * 0.3
            }
        }
        
        guard let handPos = currentHandPosition else {
            if !isGrabbing && wasGrabbing {
                dropGrabbedFood(manager: manager)
            }
            wasGrabbing = isGrabbing
            cursorEntity?.isEnabled = false
            return
        }
        
        if cursorEntity == nil {
            let sphere = ModelEntity(mesh: .generateSphere(radius: 0.02), materials: [SimpleMaterial(color: .yellow, isMetallic: false)])
            let cursorAnchor = AnchorEntity(world: .zero)
            cursorAnchor.addChild(sphere)
            arView.scene.addAnchor(cursorAnchor)
            self.cursorEntity = sphere
        }
        
        cursorEntity?.isEnabled = true
        cursorEntity?.position = handPos
        
        var isHovering = false
        var closestFoodToGrab: Entity?
        var closestDistance: Float = .infinity
        
        // Hover logic only applies if we aren't currently dragging
        if draggedFoodEntity == nil {
            for food in foodEntities {
                let nodePos = food.position(relativeTo: nil)
                let dx = nodePos.x - handPos.x
                let dy = nodePos.y - handPos.y
                let dz = nodePos.z - handPos.z
                
                let visualDistance = hypot(dx, dy)
                let depthDistance = abs(dz)
                
                if visualDistance < 0.20 && depthDistance < 0.25 {
                    isHovering = true
                    if visualDistance < closestDistance {
                        closestDistance = visualDistance
                        closestFoodToGrab = food
                    }
                }
            }
        } else {
            // We are already dragging, keep cursor green
            isHovering = true
        }
        
        if isHovering {
            cursorEntity?.model?.materials = [SimpleMaterial(color: .green, isMetallic: false)]
        } else if getDepth(at: screenPoint, in: frame, arView: arView) == nil {
            cursorEntity?.model?.materials = [SimpleMaterial(color: .red, isMetallic: false)]
        } else {
            cursorEntity?.model?.materials = [SimpleMaterial(color: .yellow, isMetallic: false)]
        }
        
        // Dragging Logic
        if isGrabbing && !wasGrabbing {
            if let targetFood = closestFoodToGrab {
                draggedFoodEntity = targetFood
                if let cursor = cursorEntity {
                    let worldTransform = targetFood.transformMatrix(relativeTo: nil)
                    targetFood.setParent(cursor)
                    targetFood.setTransformMatrix(worldTransform, relativeTo: nil)
                }
            }
        } else if !isGrabbing && wasGrabbing {
            dropGrabbedFood(manager: manager)
        }
        
        wasGrabbing = isGrabbing
        
        if isGrabbing, let draggedFood = draggedFoodEntity {
            manager.updateButterflyFlight(for: draggedFood, speed: butterflySpeed)
            
            if let butterfly = manager.animalEntity {
                let diff = butterfly.position(relativeTo: nil) - draggedFood.position(relativeTo: nil)
                let dist = length(diff)
                
                // Butterfly is close enough to eat
                if dist < 0.15 {
                    if eatingStartedAt == nil {
                        eatingStartedAt = Date()
                        audioPlayer?.currentTime = 0
                        audioPlayer?.play()
                    } else if let start = eatingStartedAt, Date().timeIntervalSince(start) > 3.0 {
                        // Success! Eaten after 3 seconds
                        draggedFood.removeFromParent()
                        if let index = foodEntities.firstIndex(of: draggedFood) {
                            foodEntities.remove(at: index)
                        }
                        self.draggedFoodEntity = nil
                        eatingStartedAt = nil
                        audioPlayer?.stop()
                        
                        manager.feedingSuccessMessage = "Yum! Butterfly ate the flower!"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if manager.feedingSuccessMessage != nil {
                                manager.feedingSuccessMessage = nil
                            }
                        }
                        
                        // Respawn if both eaten
                        if foodEntities.isEmpty {
                            spawnFood(manager: manager)
                        }
                    }
                } else {
                    audioPlayer?.stop()
                    eatingStartedAt = nil
                }
            }
        }
    }
    
    private func dropGrabbedFood(manager: ARManager) {
        if let draggedFood = draggedFoodEntity {
            draggedFood.removeFromParent()
            if let index = foodEntities.firstIndex(of: draggedFood) {
                foodEntities.remove(at: index)
            }
            // Alert user using the SwiftUI overlay (same as eating success message)
            manager.feedingSuccessMessage = "Oh no! You dropped the flower!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if manager.feedingSuccessMessage == "Oh no! You dropped the flower!" {
                    manager.feedingSuccessMessage = nil
                }
            }
            
            self.draggedFoodEntity = nil // FIX: Reset dragged entity so another can be grabbed!
            
            // Respawn if both dropped/eaten
            if foodEntities.isEmpty {
                spawnFood(manager: manager)
            }
        }
        audioPlayer?.pause()
        audioPlayer?.currentTime = 0
        eatingStartedAt = nil
    }
    
    private func getDepth(at screenPoint: CGPoint, in frame: ARFrame, arView: ARView) -> Float? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        let depthMap = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let viewSize = arView.bounds.size
        
        let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.interfaceOrientation ?? .portrait
        let transform = frame.displayTransform(for: orientation, viewportSize: viewSize).inverted()
        let normalizedPoint = CGPoint(x: screenPoint.x / viewSize.width, y: screenPoint.y / viewSize.height)
        let depthPoint = normalizedPoint.applying(transform)
        
        let pixelX = Int(depthPoint.x * CGFloat(width))
        let pixelY = Int(depthPoint.y * CGFloat(height))
        
        guard pixelX >= 0 && pixelX < width && pixelY >= 0 && pixelY < height else { return nil }
        
        if CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 {
            if let baseAddress = CVPixelBufferGetBaseAddress(depthMap) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
                var minDepth: Float = .infinity
                for dy in -2...2 {
                    for dx in -2...2 {
                        let sampleX = pixelX + dx
                        let sampleY = pixelY + dy
                        if sampleX >= 0 && sampleX < width && sampleY >= 0 && sampleY < height {
                            let rowData = baseAddress.advanced(by: sampleY * bytesPerRow)
                            let depth = rowData.assumingMemoryBound(to: Float32.self)[sampleX]
                            if depth > 0 && depth < minDepth {
                                minDepth = depth
                            }
                        }
                    }
                }
                return minDepth == .infinity ? nil : minDepth
            }
        }
        return nil
    }
}
