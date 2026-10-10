import Carbon
import AppKit

/// Global hotkey via Carbon `RegisterEventHotKey` — needs no Accessibility / Input
/// Monitoring, so it works inside the sandbox and on an MDM-managed Mac. Fixed combo ⌃⌥⌘K
/// (⌃⌥⌘ alone remains the release chord).
@MainActor
final class HotkeyMonitor {
    static let keyCodeK: UInt32 = 40
    static let modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)
    static let label = "⌃⌥⌘K"

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) { self.onPress = onPress }

    func setEnabled(_ on: Bool) {
        if on { register() } else { unregister() }
    }

    private func register() {
        guard ref == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in me.onPress() }
            return noErr
        }, 1, &spec, selfPtr, &handler)
        let id = EventHotKeyID(signature: OSType(0x4B4D4354) /* 'KMCT' */, id: 1)
        let status = RegisterEventHotKey(HotkeyMonitor.keyCodeK, HotkeyMonitor.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        DebugLog.log(status == noErr ? "hotkey: \(HotkeyMonitor.label) registered (re-grab)"
                                     : "hotkey: register failed (\(status))", status == noErr ? .info : .warn)
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
