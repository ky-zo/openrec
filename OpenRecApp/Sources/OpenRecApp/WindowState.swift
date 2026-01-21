import Foundation

final class WindowState: ObservableObject {
    @Published var isCollapsed = false {
        didSet {
            onCollapseChange?(isCollapsed)
        }
    }

    var onCollapseChange: ((Bool) -> Void)?
}
