import Foundation
import ARKit
import RealityKit
import Vision
import Combine
import SwiftUI

@available(iOS 14.0, *)
class ARManager: NSObject, ObservableObject, ARSessionDelegate {
    
    // MARK: - Published Properties
    @Published var currentMode: AppMode = .debug
    @Published var handJointPoints: [CGPoint] = []
    @Published var trackingStateMessage: String = ""
    @Published var isGrabbing: Bool = false
    @Published var isPlaced: Bool = false
    
    // MARK: - Core Components

    weak var arView: ARView? {
        didSet {
            setupARView()
        }
    }
    
    // Scene Entities
    var cursorEntity: ModelEntity?
    var parentContainer = Entity()
    var cameraAnchor: AnchorEntity?
    var animalEntity: Entity?

    
    // Vision properties
    private var currentBuffer: CVPixelBuffer?
    private let visionQueue = DispatchQueue(label: "com.example.ARKitVision.serialVisionQueue")
    private lazy var handPoseRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest(completionHandler: { [weak self] request, error in
            self?.processHandPose(for: request, error: error)
        })
        request.maximumHandCount = 1
        return request
    }()
    
    // Call-the-animal via hand gesture
    private let handCurlCallController = HandCurlCallController()
    private let callAnimalController = CallAnimalController()

    // Pinch Hysteresis properties
    private var isCurrentlyPinched = false
    private var framesSincePinchLost = 0
    private var wasGrabbing = false
    private var draggedAppleEntity: Entity?
    
    override init() {
        super.init()
    }
    
    private var currentInterfaceOrientation: UIInterfaceOrientation {
        let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        return scene?.interfaceOrientation ?? .portrait
    }
    
    private func setupARView() {
        guard let arView = arView else { return }
        
        arView.session.delegate = self
        
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        
        arView.scene.addAnchor(AnchorEntity(world: .zero)) // Root anchor
        
        let camAnchor = AnchorEntity(.camera)
        arView.scene.addAnchor(camAnchor)
        self.cameraAnchor = camAnchor
        
        // Setup shared parent container (useful for animal call mode)
        let planeAnchor = AnchorEntity(.plane(.horizontal, classification: .any, minimumBounds: SIMD2<Float>(0.2, 0.2)))
        planeAnchor.addChild(parentContainer)
        arView.scene.addAnchor(planeAnchor)
        
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard currentBuffer == nil, case .normal = frame.camera.trackingState else { return }
        self.currentBuffer = frame.capturedImage
        
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: currentBuffer!, options: [:])
        visionQueue.async {
            do {
                defer { self.currentBuffer = nil }
                try requestHandler.perform([self.handPoseRequest])
            } catch {
                print("Vision error: \(error)")
            }
        }
    }
    
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .notAvailable:
            trackingStateMessage = "Tracking Not Available"
        case .limited(let reason):
            trackingStateMessage = "Tracking Limited: \(reason)"
        case .normal:
            trackingStateMessage = ""
        }
    }
    
    // MARK: - Vision Processing
    
    private func processHandPose(for request: VNRequest, error: Error?) {
        guard let results = request.results as? [VNHumanHandPoseObservation], let hand = results.first else {
            DispatchQueue.main.async { [weak self] in
                self?.handJointPoints = []
                self?.handleHandInteraction(isGrabbing: false, normalizedPinchMidpoint: nil)
            }
            return
        }
        
        // Independent of the pinch logic below (different fingers, different
        // pose) — fires once when a held curl/beckon gesture is confirmed.
        // Only acts in Animal Call mode — the mode check happens on the main
        // thread (like every other currentMode read in this file), even
        // though the gesture detection itself runs on visionQueue.
        let shouldCallAnimal = handCurlCallController.update(hand: hand)
        if shouldCallAnimal {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentMode == .animalCall else { return }
                self.callAnimalController.callAnimal(manager: self)
            }
        }

        var pointsToDraw = [CGPoint]()
        if let recognizedPoints = try? hand.recognizedPoints(.all) {
            for (_, point) in recognizedPoints {
                guard point.confidence > 0.3 else { continue }
                pointsToDraw.append(point.location) // Normalized (0 to 1)
            }
        }
        
        var normalizedPinchMidpoint: CGPoint?
        
        if let thumbTip = try? hand.recognizedPoint(.thumbTip),
           let indexTip = try? hand.recognizedPoint(.indexTip),
           let wrist = try? hand.recognizedPoint(.wrist),
           let middleBase = try? hand.recognizedPoint(.middleMCP),
           thumbTip.confidence > 0.5, indexTip.confidence > 0.5,
           wrist.confidence > 0.5, middleBase.confidence > 0.5 {
            
            let handLength = hypot(wrist.location.x - middleBase.location.x,
                                   wrist.location.y - middleBase.location.y)
            let pinchDistance = hypot(thumbTip.location.x - indexTip.location.x,
                                      thumbTip.location.y - indexTip.location.y)
            let relativeDistance = pinchDistance / max(handLength, 0.01)
            
            if !isCurrentlyPinched && relativeDistance < 0.35 {
                isCurrentlyPinched = true
                framesSincePinchLost = 0
            } else if isCurrentlyPinched && relativeDistance > 0.65 {
                framesSincePinchLost += 1
                if framesSincePinchLost > 8 {
                    isCurrentlyPinched = false
                }
            } else if isCurrentlyPinched && relativeDistance <= 0.65 {
                framesSincePinchLost = 0
            }
            
            normalizedPinchMidpoint = CGPoint(
                x: (wrist.location.x + middleBase.location.x) / 2.0,
                y: (wrist.location.y + middleBase.location.y) / 2.0
            )
        } else {
            if isCurrentlyPinched {
                framesSincePinchLost += 1
                if framesSincePinchLost > 8 {
                    isCurrentlyPinched = false
                }
            } else {
                isCurrentlyPinched = false
            }
        }
        
        let currentPinchState = isCurrentlyPinched
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isGrabbing = currentPinchState
            
            if self.currentMode == .debug {
                self.updateDebugDots(normalizedPoints: pointsToDraw)
                self.cursorEntity?.isEnabled = false
            } else {
                self.handJointPoints = [] // Clear debug dots
            }
            
            self.handleHandInteraction(isGrabbing: currentPinchState, normalizedPinchMidpoint: normalizedPinchMidpoint)
        }
    }
    
    private func updateDebugDots(normalizedPoints: [CGPoint]) {
        guard let frame = arView?.session.currentFrame, let viewSize = arView?.bounds.size else { return }
        
        let orientation = self.currentInterfaceOrientation
        let transform = frame.displayTransform(for: orientation, viewportSize: viewSize)
        
        var screenPoints = [CGPoint]()
        for point in normalizedPoints {
            // Invert Y because Vision origin is bottom-left, displayTransform expects top-left
            let invertedYPoint = CGPoint(x: point.x, y: 1.0 - point.y)
            let viewportNormalized = invertedYPoint.applying(transform)
            screenPoints.append(CGPoint(x: viewportNormalized.x * viewSize.width,
                                        y: viewportNormalized.y * viewSize.height))
        }
        self.handJointPoints = screenPoints
    }
    
    // MARK: - Hand Interaction Logic
    
    private func handleHandInteraction(isGrabbing: Bool, normalizedPinchMidpoint: CGPoint?) {
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
        
        let orientation = self.currentInterfaceOrientation
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
    
    private func releaseGrabbedObject() {
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
    
    private func updateButterflyFlight(for apple: Entity) {
        guard let butterfly = animalEntity, let camera = cameraAnchor else { return }
        
        let cameraPos = camera.position(relativeTo: nil)
        let applePos = apple.position(relativeTo: nil)
        
        // Direction from camera to apple
        let direction = normalize(applePos - cameraPos)
        
        // Target is 5cm behind the apple (further from camera)
        let targetPos = applePos + (direction * 0.05)
        
        let currentPos = butterfly.position(relativeTo: nil)
        // Smoothly interpolate position for continuous flight
        let newPos = currentPos + (targetPos - currentPos) * 0.1
        
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
    
    private func spawnApple() {
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
    
    

    
    // MARK: - LiDAR Math
    
    private func getDepth(at screenPoint: CGPoint, in frame: ARFrame) -> Float? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        let depthMap = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let viewSize = arView?.bounds.size ?? CGSize(width: 1, height: 1)
        
        let orientation = self.currentInterfaceOrientation
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
    
    private func unproject(screenPoint: CGPoint, depth: Float, in arView: ARView) -> SIMD3<Float>? {
        if let ray = arView.ray(through: screenPoint) {
            return ray.origin + ray.direction * depth
        }
        return nil
    }
}
