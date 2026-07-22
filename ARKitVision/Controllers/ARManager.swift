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
    @Published var feedingSuccessMessage: String?
    
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
    
    let feedingController = FeedingController()

    // Pinch Hysteresis properties
    var isCurrentlyPinched = false
    var framesSincePinchLost = 0
    var wasGrabbing = false
    var draggedAppleEntity: Entity?
    
    override init() {
        super.init()
    }
    
    var currentInterfaceOrientation: UIInterfaceOrientation {
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
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
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
            
            if self.currentMode == .feeding {
                self.feedingController.update(manager: self, isGrabbing: currentPinchState, normalizedPinchMidpoint: normalizedPinchMidpoint)
            }
        }
    }
    
    

    
    // MARK: - LiDAR Math
    
    func getDepth(at screenPoint: CGPoint, in frame: ARFrame) -> Float? {
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
    
    func unproject(screenPoint: CGPoint, depth: Float, in arView: ARView) -> SIMD3<Float>? {
        if let ray = arView.ray(through: screenPoint) {
            return ray.origin + ray.direction * depth
        }
        return nil
    }
}
