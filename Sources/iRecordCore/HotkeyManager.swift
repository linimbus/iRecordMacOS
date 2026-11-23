import Carbon.HIToolbox
import Foundation

/// Registers system-wide hotkeys using the Carbon Event Manager.
/// Carbon hotkeys do not require Accessibility permission and work while
/// the app is running regardless of the frontmost application.
public final class HotkeyManager {
    public enum Action: UInt32, CaseIterable {
        case toggle = 1
        case pause = 2
        case stop = 3
    }

    public var onAction: ((Action) -> Void)?

    private static let signature: OSType = 0x49524543 // 'IREC'
    private var eventHandler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private let lock = NSLock()

    public init() {}

    deinit {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    /// Registers the three actions. Returns a set of actions that could not be registered.
    @discardableResult
    public func register(toggle: Hotkey, pause: Hotkey, stop: Hotkey) -> Set<Action> {
        unregisterAll()
        installHandlerIfNeeded()
        var failures = Set<Action>()
        if !registerOne(toggle, action: .toggle) { failures.insert(.toggle) }
        if !registerOne(pause, action: .pause) { failures.insert(.pause) }
        if !registerOne(stop, action: .stop) { failures.insert(.stop) }
        return failures
    }

    public func unregisterAll() {
        lock.lock()
        let refs = registrations
        registrations.removeAll()
        lock.unlock()
        for (_, ref) in refs {
            UnregisterEventHotKey(ref)
        }
    }

    @discardableResult
    private func registerOne(_ hotkey: Hotkey, action: Action) -> Bool {
        guard hotkey.isValid else { return false }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: action.rawValue)
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            Log.write("Hotkey registration failed for \(action) (\(hotkey.displayString)): \(status)")
            return false
        }
        lock.lock()
        registrations[action.rawValue] = ref
        lock.unlock()
        return true
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
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
                guard status == noErr, hotKeyID.signature == HotkeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                if let action = Action(rawValue: hotKeyID.id) {
                    manager.onAction?(action)
                    return noErr
                }
                return OSStatus(eventNotHandledErr)
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
    }
}
