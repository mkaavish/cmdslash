import Carbon.HIToolbox
import AppKit

/// Registers a system-wide keyboard shortcut via the Carbon Event Manager.
///
/// Carbon's `RegisterEventHotKey` is used instead of an `NSEvent` global monitor because it can
/// consume the keystroke before the frontmost app sees it, and it needs no Accessibility
/// permission grant just to register (see Docs/PLANNING.md §16).
final class GlobalHotKey {
    typealias Handler = () -> Void

    private static var handlers: [UInt32: Handler] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandlerInstalled = false
    private static let signature = OSType(0x434D_4453) // 'CMDS'

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping Handler) {
        Self.installEventHandlerIfNeeded()

        let id = Self.nextID
        Self.nextID += 1
        self.id = id
        Self.handlers[id] = handler

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Self.handlers[id] = nil
            return nil
        }
        hotKeyRef = ref
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        Self.handlers[id] = nil
        hotKeyRef = nil
    }

    deinit {
        unregister()
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
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
            guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else { return status }
            GlobalHotKey.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
