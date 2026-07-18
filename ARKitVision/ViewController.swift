/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Main view controller for the ARKitVision sample.
*/

import UIKit
import SceneKit
import ARKit
import Vision

@available(iOS 14.0, *)
class ViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate {
    
    @IBOutlet weak var sceneView: ARSCNView!
    
    enum AppMode {
        case debug
        case interact
    }
    
    private var currentMode: AppMode = .debug
    
    // MARK: - Hand Interaction Properties
    private var isCurrentlyPinched = false
    private var wasGrabbing = false
    private var currentlyGrabbedText: String?
    private var draggingLabelNode: SCNNode?
    private var handCursorNode: SCNNode?
    
    // The view controller that displays the status and "restart experience" UI.
    private lazy var statusViewController: StatusViewController = {
        return children.lazy.compactMap({ $0 as? StatusViewController }).first!
    }()
    
    // MARK: - View controller lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Configure the SceneKit scene
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.scene = SCNScene()
        sceneView.autoenablesDefaultLighting = true
        
        // Hook up status view controller callback.
        statusViewController.restartExperienceHandler = { [unowned self] in
            self.restartSession()
        }
        
        // Add Mode Switch Button
        let modeButton = UIButton(type: .system)
        modeButton.setTitle("Mode: Debug", for: .normal)
        modeButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        modeButton.setTitleColor(.white, for: .normal)
        modeButton.layer.cornerRadius = 8
        modeButton.translatesAutoresizingMaskIntoConstraints = false
        modeButton.addTarget(self, action: #selector(toggleMode(_:)), for: .touchUpInside)
        view.addSubview(modeButton)
        
        // Add Spawn Items Button
        let spawnButton = UIButton(type: .system)
        spawnButton.setTitle("Spawn Items", for: .normal)
        spawnButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.8)
        spawnButton.setTitleColor(.white, for: .normal)
        spawnButton.layer.cornerRadius = 8
        spawnButton.translatesAutoresizingMaskIntoConstraints = false
        spawnButton.addTarget(self, action: #selector(spawnRandomItems(_:)), for: .touchUpInside)
        view.addSubview(spawnButton)
        
        NSLayoutConstraint.activate([
            modeButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            modeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: -100),
            modeButton.widthAnchor.constraint(equalToConstant: 180),
            modeButton.heightAnchor.constraint(equalToConstant: 50),
            
            spawnButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            spawnButton.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: 100),
            spawnButton.widthAnchor.constraint(equalToConstant: 180),
            spawnButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }
    
    @objc func spawnRandomItems(_ sender: UIButton) {
        guard let currentFrame = sceneView.session.currentFrame else { return }
        
        for _ in 0..<3 { // Spawn 3 items
            // Create a translation matrix
            var translation = matrix_identity_float4x4
            // Randomly position in front of camera (Z between -0.4 and -0.8 meters)
            translation.columns.3.z = -Float.random(in: 0.4...0.8)
            // Randomly position left/right (X between -0.3 and 0.3 meters)
            translation.columns.3.x = Float.random(in: -0.3...0.3)
            // Randomly position up/down (Y between -0.3 and 0.3 meters)
            translation.columns.3.y = Float.random(in: -0.2...0.2)
            
            // Multiply by camera transform to place it relative to the camera's current pose
            let anchorTransform = simd_mul(currentFrame.camera.transform, translation)
            
            let anchor = ARAnchor(transform: anchorTransform)
            sceneView.session.add(anchor: anchor)
            
            // We will just use the "Apple" identifier since we have the Apple.usdz asset!
            anchorLabels[anchor.identifier] = "Apple"
        }
    }
    
    @objc func toggleMode(_ sender: UIButton) {
        if currentMode == .debug {
            currentMode = .interact
            sender.setTitle("Mode: Interact", for: .normal)
            clearHandDots()
        } else {
            currentMode = .debug
            sender.setTitle("Mode: Debug", for: .normal)
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Create a session configuration
        let configuration = ARWorldTrackingConfiguration()
        
        // Enable LiDAR mesh reconstruction if supported
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        
        // Enable raw LiDAR depth map for true 3D hand interactions
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        
        // Run the view's session
        sceneView.session.run(configuration)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Pause the view's session
        sceneView.session.pause()
    }
    
    // MARK: - ARSessionDelegate
    
    // Pass camera frames received from ARKit to Vision (when not already processing one)
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Do not enqueue other buffers for processing while another Vision task is still running.
        // The camera stream has only a finite amount of buffers available; holding too many buffers for analysis would starve the camera.
        guard currentBuffer == nil, case .normal = frame.camera.trackingState else {
            return
        }
        
        // Retain the image buffer for Vision processing.
        self.currentBuffer = frame.capturedImage
        classifyCurrentImage()
    }
    
    // MARK: - Vision classification
    
    // Vision hand pose request
    private lazy var handPoseRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest(completionHandler: { [weak self] request, error in
            self?.processHandPose(for: request, error: error)
        })
        request.maximumHandCount = 1
        
        // Use CPU for Vision processing to ensure that there are adequate GPU resources for rendering.
        request.usesCPUOnly = true
        
        return request
    }()
    
    // The pixel buffer being held for analysis; used to serialize Vision requests.
    private var currentBuffer: CVPixelBuffer?
    
    // Queue for dispatching vision classification requests
    private let visionQueue = DispatchQueue(label: "com.example.apple-samplecode.ARKitVision.serialVisionQueue")
    
    // Run the Vision+ML classifier on the current image buffer.
    private func classifyCurrentImage() {
        // By omitting the orientation, Vision processes the raw ARKit image buffer.
        // This ensures the returned coordinates are in the exact raw coordinate space,
        // which makes them align perfectly with ARKit's displayTransform mapping.
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: currentBuffer!, options: [:])
        visionQueue.async {
            do {
                // Release the pixel buffer when done, allowing the next buffer to be processed.
                defer { self.currentBuffer = nil }
                try requestHandler.perform([self.handPoseRequest])
            } catch {
                print("Error: Vision request failed with error \"\(error)\"")
            }
        }
    }
    
    // Classification results
    private var identifierString = ""
    private var confidence: VNConfidence = 0.0
    
    // Handle completion of the Vision request and choose results to display.
    func processHandPose(for request: VNRequest, error: Error?) {
        guard let results = request.results as? [VNHumanHandPoseObservation], let hand = results.first else {
            identifierString = ""
            confidence = 0
            DispatchQueue.main.async { [weak self] in
                self?.displayClassifierResults()
                self?.clearHandDots()
                self?.handleHandInteraction(isGrabbing: false, normalizedPinchMidpoint: nil)
            }
            return
        }
        
        // Extract all the joint points from the observation
        var pointsToDraw = [CGPoint]()
        if let recognizedPoints = try? hand.recognizedPoints(.all) {
            for (_, point) in recognizedPoints {
                guard point.confidence > 0.3 else { continue }
                pointsToDraw.append(point.location) // This is a normalized point (0.0 to 1.0)
            }
        }
        
        // MARK: - Smart Pinch Detection (With Hysteresis)
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
            
            // Relative distance (scales perfectly regardless of how far the hand is!)
            let relativeDistance = pinchDistance / max(handLength, 0.01)
            
            // Hysteresis using relative distance
            if !isCurrentlyPinched && relativeDistance < 0.35 {
                isCurrentlyPinched = true
            } else if isCurrentlyPinched && relativeDistance > 0.65 {
                isCurrentlyPinched = false
            }
            
            // Use the Palm Center (midpoint between Wrist and Middle Knuckle) for the 3D interaction point!
            // This is a much larger physical surface, so LiDAR is far less likely to miss it compared to thin fingertips!
            normalizedPinchMidpoint = CGPoint(
                x: (wrist.location.x + middleBase.location.x) / 2.0,
                y: (wrist.location.y + middleBase.location.y) / 2.0
            )
        } else {
            // Hand is lost or not confident, release grab
            isCurrentlyPinched = false
        }
        
        // Update the UI label based on the action
        if isCurrentlyPinched {
            identifierString = "Grabbing ✊"
        } else {
            identifierString = "Open Hand 🖐"
        }
        confidence = hand.confidence
        
        // Capture state to pass safely to the main thread
        let currentPinchState = isCurrentlyPinched
        
        DispatchQueue.main.async { [weak self] in
            self?.displayClassifierResults()
            
            if self?.currentMode == .debug {
                self?.drawHandDots(normalizedPoints: pointsToDraw)
            } else {
                self?.clearHandDots()
            }
            
            self?.handleHandInteraction(isGrabbing: currentPinchState, normalizedPinchMidpoint: normalizedPinchMidpoint)
        }
    }
    
    // MARK: - Drawing Hand Joints
    
    // Array to keep track of the drawn dots so we can remove them in the next frame
    private var handDotViews = [UIView]()
    
    private func clearHandDots() {
        for dot in handDotViews {
            dot.removeFromSuperview()
        }
        handDotViews.removeAll()
    }
    
    private func drawHandDots(normalizedPoints: [CGPoint]) {
        clearHandDots()
        
        guard let frame = sceneView.session.currentFrame else { return }
        
        // Get the transform that maps the camera image to the view's bounds
        let orientation = sceneView.window?.windowScene?.interfaceOrientation ?? .portrait
        let transform = frame.displayTransform(for: orientation, viewportSize: sceneView.bounds.size)
        
        for normalizedPoint in normalizedPoints {
            // Vision returns coordinates with origin at bottom-left. 
            // displayTransform expects origin at top-left, so we invert the Y axis.
            let invertedYPoint = CGPoint(x: normalizedPoint.x, y: 1.0 - normalizedPoint.y)
            let viewportNormalizedPoint = invertedYPoint.applying(transform)
            
            // Convert to actual screen coordinates
            let screenPoint = CGPoint(
                x: viewportNormalizedPoint.x * sceneView.bounds.width,
                y: viewportNormalizedPoint.y * sceneView.bounds.height
            )
            
            // Create and add a red dot
            let dot = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 12))
            dot.backgroundColor = .systemRed
            dot.layer.cornerRadius = 6
            dot.center = screenPoint
            sceneView.addSubview(dot)
            handDotViews.append(dot)
        }
    }
    
    // MARK: - Hand Interaction Logic
    
    private func handleHandInteraction(isGrabbing: Bool, normalizedPinchMidpoint: CGPoint?) {
        guard currentMode == .interact else {
            wasGrabbing = isGrabbing
            return
        }
        
        guard let pinchMid = normalizedPinchMidpoint, let frame = sceneView.session.currentFrame else {
            wasGrabbing = isGrabbing
            handCursorNode?.isHidden = true
            return
        }
        
        // Convert normalized pinch midpoint to screen coordinates
        let orientation = sceneView.window?.windowScene?.interfaceOrientation ?? .portrait
        let transform = frame.displayTransform(for: orientation, viewportSize: sceneView.bounds.size)
        let invertedYPoint = CGPoint(x: pinchMid.x, y: 1.0 - pinchMid.y)
        let viewportNormalizedPoint = invertedYPoint.applying(transform)
        let screenPoint = CGPoint(
            x: viewportNormalizedPoint.x * sceneView.bounds.width,
            y: viewportNormalizedPoint.y * sceneView.bounds.height
        )
        
        let currentFrame = frame
        
        // Always try to map the 3D hand cursor position while in Interact mode (even if not grabbing yet)
        var currentHandPosition: SCNVector3?
        var isHovering = false
        var closestNodeToGrab: SCNNode?
        
        if let depth = getDepth(at: screenPoint, in: currentFrame) {
            currentHandPosition = unproject(screenPoint: screenPoint, depth: depth, frame: currentFrame, viewSize: sceneView.bounds.size)
        } else {
            // LiDAR blindspot! Hand is likely closer than 30cm to the camera.
            let fallbackDepth: Float = 0.3
            currentHandPosition = unproject(screenPoint: screenPoint, depth: fallbackDepth, frame: currentFrame, viewSize: sceneView.bounds.size)
        }
        
        if let handPos = currentHandPosition {
            if handCursorNode == nil {
                let sphere = SCNSphere(radius: 0.02)
                let material = SCNMaterial()
                sphere.materials = [material]
                handCursorNode = SCNNode(geometry: sphere)
                handCursorNode?.addChildNode(createCoordinateLabelNode())
                sceneView.scene.rootNode.addChildNode(handCursorNode!)
            }
            
            // Constantly check if the hand is inside ANY Apple's Cyan Cylinder buffer!
            var closestDistance: Float = Float.infinity
            sceneView.scene.rootNode.enumerateChildNodes { (node, _) in
                guard let name = node.name, !name.isEmpty, name != "CoordinateLabel" else { return }
                
                let nodePos = node.worldPosition
                let dx = nodePos.x - handPos.x
                let dy = nodePos.y - handPos.y
                let dz = nodePos.z - handPos.z
                
                // Visual alignment (X and Y axis): Scaled to ~1.2x Apple size (0.09 meters radius)
                let visualDistance = hypot(dx, dy)
                
                // Depth alignment (Z axis): Shrink to 0.15 meters each way (30cm total)
                let depthDistance = abs(dz)
                
                if visualDistance < 0.09 && depthDistance < 0.15 {
                    isHovering = true // The hand is inside the buffer!
                    if visualDistance < closestDistance {
                        closestDistance = visualDistance
                        closestNodeToGrab = node
                    }
                }
            }
            
            // Update cursor color based on Hover / Blindspot state!
            if isHovering {
                handCursorNode?.geometry?.firstMaterial?.diffuse.contents = UIColor.green
            } else if getDepth(at: screenPoint, in: currentFrame) == nil {
                handCursorNode?.geometry?.firstMaterial?.diffuse.contents = UIColor.red
            } else {
                handCursorNode?.geometry?.firstMaterial?.diffuse.contents = UIColor.yellow
            }
            
            handCursorNode?.position = handPos
            handCursorNode?.isHidden = false
        }
        
        if isGrabbing && !wasGrabbing {
            // Started grabbing: TRUE PHYSICAL 3D GRABBING using RAW LiDAR DEPTH
            guard currentlyGrabbedText == nil else { return }
            
            // Because we already checked for hovering, we just grab the closest node!
            if let targetNode = closestNodeToGrab, let emoji = targetNode.name {
                currentlyGrabbedText = emoji
                
                // Remove anchor from AR session
                if let anchorRoot = targetNode.parent, let anchor = sceneView.anchor(for: anchorRoot) {
                    sceneView.session.remove(anchor: anchor)
                    anchorLabels.removeValue(forKey: anchor.identifier)
                } else {
                    targetNode.removeFromParentNode()
                }
                
                // Create drag node
                draggingLabelNode = createAssetNode(itemName: emoji)
                
                // Visual Feedback: Turn the grabbed Apple's buffer ORANGE while it is being held!
                if let cylinderNode = draggingLabelNode?.childNode(withName: "BufferCylinder", recursively: false) {
                    cylinderNode.geometry?.firstMaterial?.diffuse.contents = UIColor.orange
                }
                
                sceneView.scene.rootNode.addChildNode(draggingLabelNode!)
            }
        } else if isGrabbing && wasGrabbing {
            // Dragging: move the dragged 3D node
            if let draggingNode = draggingLabelNode {
                if let handPos = handCursorNode?.position, handCursorNode?.isHidden == false {
                    draggingNode.position = handPos
                } else {
                    // Fallback to a fixed depth if LiDAR doesn't hit the hand immediately
                    let zDepth: Float = 0.996
                    let projectedPoint = sceneView.unprojectPoint(SCNVector3(Float(screenPoint.x), Float(screenPoint.y), zDepth))
                    draggingNode.position = projectedPoint
                }
            }
        } else if !isGrabbing && wasGrabbing {
            // Dropped: DESTROY the object and show an eating modal
            if let grabbedText = currentlyGrabbedText {
                
                draggingLabelNode?.removeFromParentNode()
                draggingLabelNode = nil
                
                // Show the "Eating" alert
                let alert = UIAlertController(title: "Yum!", message: "You ate the \(grabbedText)!", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Delicious", style: .default, handler: nil))
                
                // Present on the main thread (we are already in DispatchQueue.main.async here)
                self.present(alert, animated: true, completion: nil)
                
                currentlyGrabbedText = nil
            }
        }
        
        wasGrabbing = isGrabbing
    }
    
    // Show the classification results in the UI.
    private func displayClassifierResults() {
        guard !self.identifierString.isEmpty else {
            return // No object was classified.
        }
        let message = String(format: "Detected \(self.identifierString) with %.2f", self.confidence * 100) + "% confidence"
        statusViewController.showMessage(message)
    }
    
    // MARK: - Tap gesture handler & ARSCNViewDelegate
    
    // Labels for classified objects by ARAnchor UUID
    private var anchorLabels = [UUID: String]()
    
    private func createCoordinateLabelNode() -> SCNNode {
        let textGeometry = SCNText(string: "Coordinates", extrusionDepth: 0.01)
        textGeometry.font = UIFont.boldSystemFont(ofSize: 10)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white
        textGeometry.materials = [material]
        
        let textNode = SCNNode(geometry: textGeometry)
        textNode.name = "CoordinateLabel"
        textNode.scale = SCNVector3(0.002, 0.002, 0.002) // Scale down the massive text
        textNode.position = SCNVector3(0, 0.15, 0) // 15cm floating above the object
        
        // A billboard constraint makes the text mathematically rotate to ALWAYS face the user's camera!
        let constraint = SCNBillboardConstraint()
        constraint.freeAxes = .Y
        textNode.constraints = [constraint]
        
        return textNode
    }
    
    private func createAssetNode(itemName: String) -> SCNNode {
        let wrapperNode = SCNNode()
        wrapperNode.name = itemName
        
        // Attempt to load the 3D asset from the bundle
        // We will try loading the itemName (e.g. "Apple.usdz")
        if let url = Bundle.main.url(forResource: itemName, withExtension: "usdz"),
           let referenceNode = SCNReferenceNode(url: url) {
            
            referenceNode.load()
            
            // We use the bounding box to perfectly scale the USDZ down to ~15cm so it fits in the hand.
            let (min, max) = referenceNode.boundingBox
            let width = max.x - min.x
            if width > 0 {
                let targetWidth: Float = 0.15 // 15 centimeters
                let scaleMultiplier = targetWidth / Swift.max(width, 0.001)
                referenceNode.scale = SCNVector3(scaleMultiplier, scaleMultiplier, scaleMultiplier)
            }
            
            // Center the model's pivot
            referenceNode.pivot = SCNMatrix4MakeTranslation((max.x - min.x)/2 + min.x, (max.y - min.y)/2 + min.y, (max.z - min.z)/2 + min.z)
            
            wrapperNode.addChildNode(referenceNode)
        } else {
            // Fallback: A solid red sphere if the USDZ is missing or named incorrectly
            let sphere = SCNSphere(radius: 0.06)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.red
            sphere.materials = [material]
            let sphereNode = SCNNode(geometry: sphere)
            wrapperNode.addChildNode(sphereNode)
        }
        
        // VISUALIZE THE CYLINDRICAL BUFFER
        // 1.2x size: Radius = 0.09, Height = 0.30
        let cylinder = SCNCylinder(radius: 0.09, height: 0.30)
        let cylinderMaterial = SCNMaterial()
        cylinderMaterial.diffuse.contents = UIColor.cyan
        cylinderMaterial.isDoubleSided = true
        cylinder.materials = [cylinderMaterial]
        
        let cylinderNode = SCNNode(geometry: cylinder)
        cylinderNode.name = "BufferCylinder"
        cylinderNode.opacity = 0.4 // Much more visible
        // SCNCylinder stands upright on the Y axis by default. We rotate it 90 degrees to point along the Z axis (depth).
        cylinderNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        
        wrapperNode.addChildNode(cylinderNode)
        
        // Add coordinate label
        wrapperNode.addChildNode(createCoordinateLabelNode())
        
        return wrapperNode
    }
    
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        if let itemName = anchorLabels[anchor.identifier] {
            return createAssetNode(itemName: itemName)
        }
        return nil
    }
    
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // Constantly update all coordinate labels in the scene with their physical 3D world position
        sceneView.scene.rootNode.enumerateChildNodes { (node, _) in
            if let textNode = node.childNode(withName: "CoordinateLabel", recursively: false),
               let textGeometry = textNode.geometry as? SCNText {
                
                let pos = node.worldPosition
                let string = String(format: "X: %.2fm\nY: %.2fm\nZ: %.2fm", pos.x, pos.y, pos.z)
                
                if textGeometry.string as? String != string {
                    textGeometry.string = string
                    
                    // Recenter the pivot so the text stays perfectly centered above the object
                    let (min, max) = textGeometry.boundingBox
                    textNode.pivot = SCNMatrix4MakeTranslation((max.x - min.x)/2 + min.x, (max.y - min.y)/2 + min.y, 0)
                }
            }
        }
    }
    
    // When the user taps, add an anchor associated with the current classification result.
    @IBAction func placeLabelAtLocation(sender: UITapGestureRecognizer) {
        let hitLocationInView = sender.location(in: sceneView)
        // hitTest is deprecated but kept for backwards compatibility in this sample
        let hitTestResults = sceneView.hitTest(hitLocationInView, types: [.featurePoint, .estimatedHorizontalPlane])
        if let result = hitTestResults.first {
            
            // Add a new anchor at the tap location.
            let anchor = ARAnchor(transform: result.worldTransform)
            sceneView.session.add(anchor: anchor)
            
            // Track anchor ID to associate text with the anchor after ARKit creates a corresponding SCNNode.
            anchorLabels[anchor.identifier] = identifierString
        }
    }
    
    // MARK: - AR Session Handling
    
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        statusViewController.showTrackingQualityInfo(for: camera.trackingState, autoHide: true)
        
        switch camera.trackingState {
        case .notAvailable, .limited:
            statusViewController.escalateFeedback(for: camera.trackingState, inSeconds: 3.0)
        case .normal:
            statusViewController.cancelScheduledMessage(for: .trackingStateEscalation)
            // Unhide content after successful relocalization.
            setOverlaysHidden(false)
        }
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        guard error is ARError else { return }
        
        let errorWithInfo = error as NSError
        let messages = [
            errorWithInfo.localizedDescription,
            errorWithInfo.localizedFailureReason,
            errorWithInfo.localizedRecoverySuggestion
        ]
        
        // Filter out optional error messages.
        let errorMessage = messages.compactMap({ $0 }).joined(separator: "\n")
        DispatchQueue.main.async {
            self.displayErrorMessage(title: "The AR session failed.", message: errorMessage)
        }
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        setOverlaysHidden(true)
    }
    
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        /*
         Allow the session to attempt to resume after an interruption.
         This process may not succeed, so the app must be prepared
         to reset the session if the relocalizing status continues
         for a long time -- see `escalateFeedback` in `StatusViewController`.
         */
        return true
    }

    private func setOverlaysHidden(_ shouldHide: Bool) {
        sceneView.scene.rootNode.childNodes.forEach { node in
            if shouldHide {
                // Hide overlay content immediately during relocalization.
                node.opacity = 0
            } else {
                // Fade overlay content in after relocalization succeeds.
                node.runAction(.fadeOpacity(to: 1.0, duration: 0.5))
            }
        }
    }

    private func restartSession() {
        statusViewController.cancelAllScheduledMessages()
        statusViewController.showMessage("RESTARTING SESSION")

        anchorLabels = [UUID: String]()
        
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }
    
    // MARK: - Error handling
    
    private func displayErrorMessage(title: String, message: String) {
        // Present an alert informing about the error that has occurred.
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let restartAction = UIAlertAction(title: "Restart Session", style: .default) { _ in
            alertController.dismiss(animated: true, completion: nil)
            self.restartSession()
        }
        alertController.addAction(restartAction)
        present(alertController, animated: true, completion: nil)
    }
    
    // MARK: - True 3D LiDAR Math
    
    private func getDepth(at screenPoint: CGPoint, in frame: ARFrame) -> Float? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        
        let depthMap = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        
        let viewSize = sceneView.bounds.size
        
        let transform = frame.displayTransform(for: sceneView.window?.windowScene?.interfaceOrientation ?? .portrait, viewportSize: viewSize).inverted()
        let normalizedPoint = CGPoint(x: screenPoint.x / viewSize.width, y: screenPoint.y / viewSize.height)
        let depthPoint = normalizedPoint.applying(transform)
        
        let pixelX = Int(depthPoint.x * CGFloat(width))
        let pixelY = Int(depthPoint.y * CGFloat(height))
        
        guard pixelX >= 0 && pixelX < width && pixelY >= 0 && pixelY < height else { return nil }
        
        if CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 {
            if let baseAddress = CVPixelBufferGetBaseAddress(depthMap) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
                
                // Sample a 5x5 grid around the pixel to find the finger (which is the closest object)
                var minDepth: Float = Float.infinity
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
                
                return minDepth == Float.infinity ? nil : minDepth
            }
        }
        return nil
    }
    
    private func unproject(screenPoint: CGPoint, depth: Float, frame: ARFrame, viewSize: CGSize) -> SCNVector3 {
        // SceneKit's unprojectPoint handles all complex camera rotations, orientations, and projection matrices flawlessly!
        // We project a point near the camera (Z = 0.0) and far from the camera (Z = 1.0) to create a perfect 3D ray.
        let nearPoint = sceneView.unprojectPoint(SCNVector3(Float(screenPoint.x), Float(screenPoint.y), 0.0))
        let farPoint = sceneView.unprojectPoint(SCNVector3(Float(screenPoint.x), Float(screenPoint.y), 1.0))
        
        let ray = SCNVector3(
            farPoint.x - nearPoint.x,
            farPoint.y - nearPoint.y,
            farPoint.z - nearPoint.z
        )
        let rayLength = hypot(hypot(ray.x, ray.y), ray.z)
        let normalizedRay = SCNVector3(ray.x / rayLength, ray.y / rayLength, ray.z / rayLength)
        
        // The camera's true position in the 3D world
        let cameraPos = sceneView.pointOfView!.worldPosition
        
        // Walk 'depth' meters down the ray to find the exact 3D physical location!
        return SCNVector3(
            cameraPos.x + normalizedRay.x * depth,
            cameraPos.y + normalizedRay.y * depth,
            cameraPos.z + normalizedRay.z * depth
        )
    }
}
