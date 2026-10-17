import AppKit
import HouseUIKit

extension PanelModel: MenuPanelModeling {}

/// Memory's panel window. Opening starts on the rows; the four command chords
/// work whether or not a field has focus.
@MainActor
final class MenuBarPanelController: MenuPanelController<MenuBarPanelView, PanelModel> {
    init(model: PanelModel) {
        super.init(model: model, width: MenuBarPanelView.width, rootView: { MenuBarPanelView(model: model) })
    }

    override func panelWillShow() {
        model.mode = .rows
        model.selection = 0
        model.panelOpened()
    }

    override func panelDidClose() {
        model.isPanelOpen = false
    }

    /// The command chords are handled here rather than as SwiftUI shortcuts so
    /// they work identically whether or not a field has focus.
    override func handle(_ key: PanelKeyPress) -> Bool {
        if key.flags.contains(.command) {
            switch key.characters?.lowercased() {
            case "n": model.beginCapture(); return true
            case "f": model.beginSearch(); return true
            case "t": model.beginToday(); return true
            case ",": model.onOpenSettings(); return true
            case "q": model.onQuit(); return true
            default: return false
            }
        }
        return super.handle(key)
    }
}
