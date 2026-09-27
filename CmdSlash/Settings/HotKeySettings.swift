import Carbon.HIToolbox
import Foundation

/// Persisted, user-remappable global hotkey (Docs/PLANNING.md §16) — UserDefaults-backed since
/// this is a plain preference, not a secret. Previously hardcoded to ⌘/ in AppDelegate; that
/// value is now just this type's default.
enum HotKeySettings {
    static let hotKeyChangedNotification = Notification.Name("com.cmdslash.hotKeyChanged")

    private static let keyCodeDefaultsKey = "HotKeyKeyCode"
    private static let modifiersDefaultsKey = "HotKeyModifiers"

    /// ⌘/ — the app's original, still-default binding.
    private static let defaultKeyCode = UInt32(kVK_ANSI_Slash)
    private static let defaultModifiers = UInt32(cmdKey)

    static var keyCode: UInt32 {
        (UserDefaults.standard.object(forKey: keyCodeDefaultsKey) as? Int).map(UInt32.init) ?? defaultKeyCode
    }

    static var modifiers: UInt32 {
        (UserDefaults.standard.object(forKey: modifiersDefaultsKey) as? Int).map(UInt32.init) ?? defaultModifiers
    }

    static func save(keyCode: UInt32, modifiers: UInt32) {
        UserDefaults.standard.set(Int(keyCode), forKey: keyCodeDefaultsKey)
        UserDefaults.standard.set(Int(modifiers), forKey: modifiersDefaultsKey)
        NotificationCenter.default.post(name: hotKeyChangedNotification, object: nil)
    }

    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: keyCodeDefaultsKey)
        UserDefaults.standard.removeObject(forKey: modifiersDefaultsKey)
        NotificationCenter.default.post(name: hotKeyChangedNotification, object: nil)
    }

    /// Human-readable description for display — a small, deliberately incomplete keyCode->symbol
    /// map covering common keys (letters, digits, common punctuation, a few named keys) rather
    /// than Carbon's full virtual-keycode space; falls back to "Key <code>" for anything unmapped
    /// rather than guessing wrong.
    static func description(keyCode: UInt32? = nil, modifiers: UInt32? = nil) -> String {
        let keyCode = keyCode ?? Self.keyCode
        let modifiers = modifiers ?? Self.modifiers

        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }

        return symbols + keySymbol(for: keyCode)
    }

    private static func keySymbol(for keyCode: UInt32) -> String {
        let map: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D",
            UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F", UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H",
            UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O", UInt32(kVK_ANSI_P): "P",
            UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R", UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
            UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
            UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5", UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7",
            UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
            UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Minus): "-",
            UInt32(kVK_ANSI_Equal): "=", UInt32(kVK_ANSI_Grave): "`", UInt32(kVK_ANSI_Backslash): "\\",
            UInt32(kVK_Space): "Space", UInt32(kVK_Tab): "⇥", UInt32(kVK_Return): "↵", UInt32(kVK_Escape): "⎋"
        ]
        return map[keyCode] ?? "Key \(keyCode)"
    }
}
