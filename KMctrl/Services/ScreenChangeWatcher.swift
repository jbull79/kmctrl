import AppKit

/// Calls back once the display setup settles after a change — a monitor plugged in or
/// unplugged, a resolution or arrangement change, a lid opened. macOS posts several
/// notifications per change, so they are collapsed into one call half a second after the last.
@MainActor
final class ScreenChangeWatcher {
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?

    func start(_ onChange: @escaping @MainActor () -> Void) {
        stop()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pending?.cancel()
                self.pending = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    onChange()
                }
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pending?.cancel(); pending = nil
    }
}
