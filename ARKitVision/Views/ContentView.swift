import SwiftUI

@available(iOS 14.0, *)
struct ContentView: View {
    @StateObject private var arManager = ARManager()
    
    var body: some View {
        ZStack {
            // Background AR View
            ARViewContainer(manager: arManager)
                .edgesIgnoringSafeArea(.all)
            
            // 2D Debug Dots Layer
            if arManager.currentMode == .debug {
                ForEach(0..<arManager.handJointPoints.count, id: \.self) { index in
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                        .position(arManager.handJointPoints[index])
                }
            }
            
            // UI Overlay
            VStack {
                if !arManager.trackingStateMessage.isEmpty {
                    Text(arManager.trackingStateMessage)
                        .font(.headline)
                        .padding()
                        .background(Color.black.opacity(0.6))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .padding(.top, 40)
                }
                
                Spacer()
                
                if arManager.currentMode == .debug {
                    Text(arManager.isGrabbing ? "Grabbing ✊" : "Open Hand 🖐")
                        .font(.title2)
                        .padding()
                        .background(Color.black.opacity(0.6))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .padding(.bottom, 10)
                }
                
                if arManager.currentMode == .animalCall {
                    AnimalCallScene(manager: arManager)
                }
                
                if arManager.currentMode == .feeding {
                    FeedingScene(manager: arManager)
                }

                
                // Mode Switcher
                Picker("App Mode", selection: $arManager.currentMode) {
                    ForEach(AppMode.allCases.filter { $0.isVisible }) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                .background(Color.black.opacity(0.5))
                .cornerRadius(10)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }
}
