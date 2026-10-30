import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var tracker: Tracker?
    private var calibration: Calibration?
    private var settings: NSWindow?
    private var hotKey: EventHotKeyRef?
    private var active = false

    private var savedMap: GazeMap? {
        UserDefaults.standard.data(forKey: "gazeMap").flatMap { try? JSONDecoder().decode(GazeMap.self, from: $0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.addItem(withTitle: "Calibrate…", action: #selector(calibrate), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Vizor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        setActive(false)

        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, me in
            let app = Unmanaged<AppDelegate>.fromOpaque(me!).takeUnretainedValue()
            DispatchQueue.main.async { app.toggle() }
            return OSStatus(noErr)
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), nil)
        registerHotKey()
    }

    /// Left click toggles; right click (or control-click) opens the menu.
    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            toggle()
        }
    }

    func toggle() {
        if active { return setActive(false) }
        withCamera {
            if let map = self.savedMap {
                self.tracker?.setMap(map)
                self.setActive(true)
            } else {
                self.runCalibration()
            }
        }
    }

    @objc private func calibrate() { withCamera { self.runCalibration() } }

    private func setActive(_ on: Bool) {
        active = on
        if !on { tracker?.stop() }
        item.button?.image = NSImage(systemSymbolName: on ? "eye.fill" : "eye.slash",
                                     accessibilityDescription: on ? "Vizor on" : "Vizor off")
    }

    /// Makes sure Vizor may move the pointer and use the camera, then starts the camera.
    private func withCamera(_ then: @escaping () -> Void) {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else { return }  // macOS shows its own Accessibility prompt
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted else {
                    return self.alert("Vizor needs the camera. Allow it in System Settings → Privacy & Security → Camera.")
                }
                do {
                    if self.tracker == nil { self.tracker = try Tracker() }
                    self.tracker?.start()
                    then()
                } catch {
                    self.alert("Couldn't start eye tracking: \(error.localizedDescription)")
                }
            }
        }
    }

    private func runCalibration() {
        guard calibration == nil, let tracker else { return }
        tracker.setMap(nil)
        calibration = Calibration(tracker: tracker) { map, open in
            self.calibration = nil
            if let map {
                UserDefaults.standard.set(try? JSONEncoder().encode(map), forKey: "gazeMap")
                UserDefaults.standard.set(open, forKey: "openBaseline")
            } else {
                self.alert("Calibration didn't work. Face the camera in good light, keep your head still and follow the dot with your eyes.")
                guard self.active else { return self.setActive(false) }  // otherwise keep the previous calibration
            }
            tracker.setMap(self.savedMap)
            self.setActive(true)
        }
    }

    @objc private func openSettings() {
        if settings == nil {
            let view = SettingsView(recalibrate: { [weak self] in self?.calibrate() },
                                    shortcutChanged: { [weak self] in self?.registerHotKey() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Vizor Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settings = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }

    private func registerHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        let defaults = UserDefaults.standard
        let status = RegisterEventHotKey(UInt32(defaults.integer(forKey: "hotKeyCode")), UInt32(defaults.integer(forKey: "hotKeyMods")),
                                         EventHotKeyID(signature: 0x5649_5A52, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if status != OSStatus(noErr) { alert("That on/off shortcut is already used by another app. Pick a different one in Settings.") }
    }

    private func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Vizor"
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

UserDefaults.standard.register(defaults: [
    "smoothing": 0.8, "blinkWindow": 0.5, "blinkThreshold": 0.55,
    "hotKeyCode": kVK_ANSI_E, "hotKeyMods": controlKey | optionKey, "hotKeyName": "E",
])
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
