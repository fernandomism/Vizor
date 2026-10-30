import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var tracker: Tracker?
    private var calibration: Calibration?
    private var zoom: Zoom?
    private var settings: NSWindow?
    private var hotKey: EventHotKeyRef?
    private var monitors: [Any] = []
    private var active = false

    /// Calibration dots plus what's been learned from clicks; nil until a calibration that works.
    private var savedSamples: [GazeSample]? {
        let samples = UserDefaults.standard.data(forKey: "gazeSamples").flatMap { try? JSONDecoder().decode([GazeSample].self, from: $0) }
        return samples.flatMap { GazeModel(samples: $0) } == nil ? nil : samples
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.addItem(withTitle: "Calibrate…", action: #selector(calibrate), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Train (100 dots)…", action: #selector(train), keyEquivalent: "").target = self
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
        if active { return stop() }
        withCamera {
            if let samples = self.savedSamples {
                self.tracker?.use(samples)
                self.setActive(true)
            } else {
                self.runCalibration()
            }
        }
    }

    @objc private func calibrate() { withCamera { self.runCalibration() } }
    @objc private func train() { withCamera { self.runCalibration(training: true) } }

    /// Turns everything off: pointer, camera, zoom and any calibration in progress. Dots already
    /// done in a calibration or training are kept when there are enough to steer with.
    private func stop() {
        if let progress = calibration?.cancel(), GazeModel(samples: progress.samples) != nil {
            save(progress.samples, open: progress.open, accuracy: 0)
        }
        calibration = nil
        zoom?.close()
        zoom = nil
        tracker?.setZoomed(false)
        setActive(false)
    }

    /// A double or triple blink: click where the pointer is, or with zoom to click, magnify first and
    /// click the real spot under the pointer on the next blinks.
    private func blinked(_ count: Int, at point: CGPoint) {
        guard let tracker else { return }
        if let zoom {
            self.zoom = nil
            zoom.close()
            tracker.setZoomed(false)
            let target = zoom.region.unzoom(point, in: zoom.screen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { tracker.click(count, at: target) }  // once the zoom view is gone
        } else if count == 2, UserDefaults.standard.bool(forKey: "zoomToClick") {
            Zoom.open(around: point, factor: CGFloat(UserDefaults.standard.double(forKey: "zoomLevel"))) { zoom in
                guard let zoom else {
                    return self.alert("Zoom to click needs macOS 14 or newer and the Screen Recording permission. Allow Vizor in System Settings → Privacy & Security → Screen Recording.")
                }
                guard self.active else { return zoom.close() }  // stopped while the snapshot was taken
                self.zoom = zoom
                tracker.setZoomed(true)
            }
        } else {
            tracker.click(count, at: point)
        }
    }

    /// Saves a finished or stopped calibration. Starting over also clears what was learned from
    /// clicks, so nothing learned at an old seat lingers.
    private func save(_ samples: [GazeSample], open: Double, accuracy: Double) {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(samples), forKey: "gazeSamples")
        defaults.set(open, forKey: "openBaseline")
        defaults.set(accuracy, forKey: "calibrationAccuracy")
        defaults.removeObject(forKey: "recentAccuracy")
    }

    /// Esc always stops Vizor, whichever app is in front, and real clicks teach it where you look.
    /// Seeing other apps' keys and clicks needs the Accessibility permission, so this waits for it.
    private func watchInput() {
        guard monitors.isEmpty else { return }
        let stopOnEscape: (NSEvent) -> Void = { event in
            if Int(event.keyCode) == kVK_Escape { self.stop() }
        }
        monitors = [NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: stopOnEscape),
                    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { stopOnEscape($0); return $0 },
                    NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                        self.tracker?.userClicked()
                    }].compactMap { $0 }
    }

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
        watchInput()
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted else {
                    return self.alert("Vizor needs the camera. Allow it in System Settings → Privacy & Security → Camera.")
                }
                do {
                    if self.tracker == nil {
                        guard let camera = AVCaptureDevice.default(for: .video) else { return self.alert("No camera found.") }
                        self.tracker = try Tracker(camera: camera)
                        self.tracker?.onBlinks = { [weak self] count, point in self?.blinked(count, at: point) }
                    }
                    self.tracker?.start()
                    then()
                } catch {
                    self.alert("Couldn't start eye tracking: \(error.localizedDescription)")
                }
            }
        }
    }

    private func runCalibration(training: Bool = false) {
        guard calibration == nil, let tracker else { return }
        tracker.use(nil)
        calibration = Calibration(tracker: tracker, training: training) { samples, open, accuracy in
            self.calibration = nil
            if let samples {
                self.save(samples, open: open, accuracy: accuracy)
            } else {
                self.alert("Calibration didn't work. Face the camera in good light, keep your head still and follow the dot with your eyes.")
                guard self.active else { return self.setActive(false) }  // otherwise keep the previous calibration
            }
            tracker.use(self.savedSamples)
            self.setActive(true)
        }
    }

    @objc private func openSettings() {
        if settings == nil {
            let view = SettingsView(recalibrate: { [weak self] in self?.calibrate() },
                                    train: { [weak self] in self?.train() },
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
    "smoothing": 0.8, "blinkWindow": 0.5, "blinkThreshold": 0.55, "holdRadius": 50.0, "zoomLevel": 3.0,
    "hotKeyCode": kVK_ANSI_E, "hotKeyMods": controlKey | optionKey, "hotKeyName": "E",
])
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
