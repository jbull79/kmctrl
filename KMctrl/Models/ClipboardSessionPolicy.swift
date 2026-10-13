import Foundation

/// What the controlling Mac's clipboard sync should do on each control-state transition.
/// Clipboard follows the keyboard: activate when the peer accepts us, push when we start
/// controlling (every grab, so a copy made between grabs is handed over), tear down when
/// the session ends. Release itself sends nothing — the controlled Mac pushes back.
enum ClipboardSessionPolicy {
    enum Action: Equatable { case none, activate, push, deactivate }

    static func action(from old: ControlHost.State, to new: ControlHost.State) -> Action {
        switch (old, new) {
        case (.connecting, .connected): return .activate
        case (_, .capturing):          return .push
        case (.connected, .idle), (.capturing, .idle): return .deactivate
        default:                       return .none
        }
    }
}
