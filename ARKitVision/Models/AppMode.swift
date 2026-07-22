import Foundation

enum AppMode: String, CaseIterable, Identifiable {
    case debug = "Debug"
    case interact = "Interact"
    case animalCall = "Animal Call"
    case feeding = "Feeding"
    
    var id: String { self.rawValue }
    
    var isVisible: Bool {
        return self == .animalCall || self == .feeding
    }
}
