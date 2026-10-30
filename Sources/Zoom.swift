import AppKit
import ScreenCaptureKit

/// Zoom to click: a magnified snapshot of the area around the pointer, covering the main screen.
/// Vizor keeps steering the real pointer over it; `region.unzoom` finds the real spot to click.
final class Zoom {
    let region: ZoomRegion
    let screen: CGRect  // pointer coordinates of the main display
    private let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)

    /// Snapshots the screen, then calls `ready` on the main thread with the zoom view showing, or with
    /// nil when the screen couldn't be captured (macOS 13, or no Screen Recording permission).
    static func open(around point: CGPoint, factor: CGFloat, ready: @escaping (Zoom?) -> Void) {
        guard #available(macOS 14.0, *) else { return ready(nil) }
        let screen = CGDisplayBounds(CGMainDisplayID())
        let region = ZoomRegion(around: point, in: screen, factor: factor)
        Task {
            let image = try? await snapshot(region.rect, of: screen)
            await MainActor.run { ready(image.map { Zoom(region: region, screen: screen, image: $0) }) }
        }
    }

    private init(region: ZoomRegion, screen: CGRect, image: CGImage) {
        self.region = region
        self.screen = screen
        let frame = NSScreen.screens[0].frame  // shortcut: main display only, like calibration
        let view = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        view.image = NSImage(cgImage: image, size: frame.size)
        view.imageScaling = .scaleAxesIndependently
        let label = NSTextField(labelWithString: "  Zoomed \(Int(region.factor))× · blink twice on the target to click · Esc stops  ")
        label.font = .systemFont(ofSize: 18)
        label.textColor = .white
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: frame.midX - label.frame.width / 2, y: frame.height - 70))
        view.addSubview(label)
        window.contentView = view
        window.setFrame(frame, display: false)
        window.level = .screenSaver
        window.ignoresMouseEvents = true  // the pointer moves over it freely
        window.orderFrontRegardless()  // without taking focus from the app you're clicking in
    }

    func close() { window.orderOut(nil) }
}

/// The main display as a picture, cropped to `rect` (both in pointer coordinates).
@available(macOS 14.0, *)
private func snapshot(_ rect: CGRect, of screen: CGRect) async throws -> CGImage? {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { return nil }
    let config = SCStreamConfiguration()
    config.width = display.width * 2  // Retina detail, so the magnified view stays sharp
    config.height = display.height * 2
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    let s = CGFloat(image.width) / screen.width
    let pixels = CGRect(x: (rect.minX - screen.minX) * s, y: (rect.minY - screen.minY) * s, width: rect.width * s, height: rect.height * s)
    return image.cropping(to: pixels)
}
