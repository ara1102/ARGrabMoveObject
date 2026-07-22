import SwiftUI

@available(iOS 14.0, *)
struct FeedingScene: View {
    @ObservedObject var manager: ARManager
    
    var body: some View {
        VStack {
            Spacer()
            
            if !manager.isPlaced {
                Text("Taruh hewan dulu di mode Animal Call")
                    .font(.subheadline)
                    .padding()
                    .background(.thinMaterial)
                    .cornerRadius(20)
                    .padding(.bottom, 20)
            } else if let message = manager.feedingSuccessMessage {
                Text(message)
                    .font(.subheadline)
                    .padding()
                    .background(.thinMaterial)
                    .cornerRadius(20)
                    .padding(.bottom, 20)
                    .transition(.opacity)
            } else {
                Text("Pinch the flower to feed!")
                    .font(.subheadline)
                    .padding()
                    .background(.thinMaterial)
                    .cornerRadius(20)
                    .padding(.bottom, 20)
            }
        }
        .animation(.easeInOut, value: manager.feedingSuccessMessage)
        .onAppear {
            if manager.isPlaced {
                manager.feedingController.spawnFood(manager: manager)
            }
        }
    }
}
