import Foundation

enum AppMode: String, CaseIterable, Identifiable {
    case debug = "Debug"
    case interact = "Interact"
    case animalCall = "Animal Call"
    
    var id: String { self.rawValue }
}
