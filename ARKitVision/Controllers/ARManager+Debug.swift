import Foundation
import ARKit
import RealityKit
import SwiftUI

@available(iOS 14.0, *)
extension ARManager {
    
    func updateDebugDots(normalizedPoints: [CGPoint]) {
        guard let frame = arView?.session.currentFrame, let viewSize = arView?.bounds.size else { return }
        
        let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.interfaceOrientation ?? .portrait
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
}
