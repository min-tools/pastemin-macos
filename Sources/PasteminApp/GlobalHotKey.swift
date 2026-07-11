import Carbon
import Foundation

private let clipboardHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    // Reject unrelated Carbon events before recovering the retained manager pointer.
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == GlobalHotKeyManager.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.invoke()
    return noErr
}

final class GlobalHotKeyManager {
    fileprivate static let signature = OSType(0x434C4950) // CLIP

    var onPressed: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init() {
        // Install one process-wide handler; individual shortcuts can then be replaced safely.
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            clipboardHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    func register(_ shortcut: GlobalShortcut) -> Bool {
        // Carbon rejects collisions, allowing the options menu to report an unavailable shortcut.
        unregister()
        guard eventHandlerRef != nil else { return false }
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        return RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &hotKeyRef
        ) == noErr && hotKeyRef != nil
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    fileprivate func invoke() {
        DispatchQueue.main.async { [weak self] in self?.onPressed?() }
    }
}
