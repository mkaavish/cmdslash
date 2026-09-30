import SwiftUI
import AppKit
import Carbon.HIToolbox

/// The companion window's Settings section (Docs/PLANNING.md §16) — the global hotkey
/// (previously hardcoded to ⌘/) and launch-at-login, the two settings expected of any menu-bar
/// utility. Connectors is the next section planned, not built yet.
struct SettingsView: View {
    @State private var hotKeyDescription = HotKeySettings.description()
    @State private var isRecording = false
    @State private var eventMonitor: Any?
    @State private var launchAtLogin = LaunchAtLoginSettings.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Toggle CmdSlash")
                    Spacer()
                    Button(isRecording ? "Press keys..." : hotKeyDescription) {
                        startRecording()
                    }
                    .frame(minWidth: 90)
                    if !isRecording {
                        Button("Reset") {
                            HotKeySettings.resetToDefault()
                            hotKeyDescription = HotKeySettings.description()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                        .font(.footnote)
                    }
                }
                Text("Click, then press the new key combination. Must include at least one modifier key (⌘, ⌥, ⌃, or ⇧).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Toggle("Launch CmdSlash at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLoginSettings.setEnabled(newValue)
                }

            Spacer()
        }
        .padding(28)
        .frame(minWidth: 420, minHeight: 300)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        // A local monitor, not a custom first-responder NSView — simpler for a one-shot "press
        // the next key combo" capture than building a whole recorder control, and this window
        // already has key focus by virtue of being frontmost when the button is clicked.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = Self.carbonModifiers(from: event.modifierFlags)
            // Require at least one modifier — a bare, unmodified key as a global hotkey would
            // fire on every ordinary keystroke of that key system-wide. Keep listening rather
            // than capturing an unmodified key silently.
            guard modifiers != 0 else { return event }
            HotKeySettings.save(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            hotKeyDescription = HotKeySettings.description()
            stopRecording()
            return nil // swallow the keystroke so it doesn't also act on whatever's behind this window
        }
    }

    private func stopRecording() {
        isRecording = false
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

#Preview {
    SettingsView()
}
