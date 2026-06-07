import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut, registered with Carbon's `RegisterEventHotKey`.
///
/// We use the Carbon API rather than an `NSEvent` global monitor for two reasons: it
/// fires even when the app is unfocused (the whole point — start/stop a recording without
/// switching to the app), and it needs **no Accessibility permission** (an `NSEvent`
/// keyboard monitor would). The registered key is consumed cleanly by the system hot-key
/// machinery, so it doesn't leak to the frontmost app.
///
/// `action` is invoked on the main thread (the application event target runs there), so
/// callers hop to the main actor inside it.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// `keyCode` is a virtual key code (e.g. `kVK_ANSI_R`); `modifiers` is a Carbon mask
    /// (e.g. `cmdKey | controlKey`).
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()

        // The handler must be a non-capturing C function; it recovers `self` from the
        // user-data pointer and forwards to the stored closure.
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
                return noErr
            },
            1,
            &eventType,
            context,
            &handlerRef
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: 0x4D_54_4B_59 /* 'MTKY' */, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
