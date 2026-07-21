import SwiftUI
import RealityKit

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var manager: ARManager
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        // Important: assign arView to manager so it can configure and run the session
        manager.arView = arView
        
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        // Handle updates if needed, though most state is managed in ARManager.
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(manager: manager)
    }
    
    class Coordinator: NSObject {
        var manager: ARManager
        
        init(manager: ARManager) {
            self.manager = manager
        }
        
        @objc func handleTap(_ sender: UITapGestureRecognizer) {
            guard let view = sender.view as? ARView else { return }
            let location = sender.location(in: view)
            manager.handleTap(at: location)
        }
    }
}
