import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @AppStorage("smoothing") private var smoothing = 0.8
    @AppStorage("blinkWindow") private var blinkWindow = 0.5
    @AppStorage("blinkThreshold") private var blinkThreshold = 0.55
    @AppStorage("holdRadius") private var holdRadius = 50.0
    @AppStorage("hotKeyCode") private var keyCode = kVK_ANSI_E
    @AppStorage("hotKeyMods") private var mods = controlKey | optionKey
    @AppStorage("hotKeyName") private var keyName = "E"
    @AppStorage("calibrationAccuracy") private var calibrationAccuracy = 0.0
    @AppStorage("recentAccuracy") private var recentAccuracy = 0.0
    @State private var monitor: Any?  // set while recording a shortcut
    let recalibrate: () -> Void
    let shortcutChanged: () -> Void

    var body: some View {
        Form {
            LabeledContent("On/off shortcut") {
                Button(monitor != nil ? "Type a shortcut… (Esc cancels)" : shortcut) { record() }
            }
            Slider(value: $smoothing, in: 0...0.95) { Text("Pointer smoothing") }
            Slider(value: $holdRadius, in: 10...150) { Text("Hold still within") }
            Slider(value: $blinkThreshold, in: 0.3...0.8) { Text("Blink sensitivity") }
            Slider(value: $blinkWindow, in: 0.3...1) { Text("Time between blinks") }
            Text("The pointer only moves when your eyes move farther than \(Int(holdRadius)) points. Blink twice to left click, three times to right click. Esc always stops Vizor.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if calibrationAccuracy > 0 {
                LabeledContent("Accuracy") {
                    Text(recentAccuracy > 0
                         ? "about \(Int(recentAccuracy)) points from your recent clicks (\(Int(calibrationAccuracy)) after calibrating)"
                         : "about \(Int(calibrationAccuracy)) points after calibrating; it improves as you click")
                }
            }
            Button("Recalibrate…", action: recalibrate)
        }
        .padding(20)
        .frame(width: 420)
    }

    private var shortcut: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { mods & $0.0 != 0 }.map { $0.1 }.joined() + keyName
    }

    private func record() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let f = event.modifierFlags
            let m = (f.contains(.control) ? controlKey : 0) | (f.contains(.option) ? optionKey : 0)
                | (f.contains(.shift) ? shiftKey : 0) | (f.contains(.command) ? cmdKey : 0)
            if Int(event.keyCode) != kVK_Escape {
                guard m & ~shiftKey != 0 else { return nil }  // needs ⌃, ⌥ or ⌘ so normal typing never toggles
                keyCode = Int(event.keyCode)
                mods = m
                keyName = event.charactersIgnoringModifiers?.uppercased() ?? "?"
                shortcutChanged()
            }
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            return nil
        }
    }
}
