import CGVirtualDisplay
import Foundation

/// A display for a Mac that has none to show: its lid shut and nothing
/// plugged in, so the built-in screen sleeps and ScreenCaptureKit finds no
/// display. Made while someone is watching; when the process is gone,
/// macOS puts its own headless 1920×1080 in its place.
///
/// The size is an M2 Air's default, 1470×956 points at 2×, until a viewer
/// asks for its own (`resize`): a phone's half screen, say, filled pixel
/// for pixel.
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    var id: CGDirectDisplayID { display.displayID }
    private(set) var size: (width: Int, height: Int)

    static let vendor: UInt32 = 0x4C4D, product: UInt32 = 0x5343
    static let defaultSize = (width: 1470, height: 956)

    // Room to grow into: the descriptor's maximum can't change later.
    private static let maxPixels = 4096
    private static var serial: UInt32 = 0
    private static let queue = DispatchQueue(label: "virtual display")

    init?(width: Int = defaultSize.width, height: Int = defaultSize.height) {
        let d = CGVirtualDisplayDescriptor()
        // Its own, not main: `choose` waits on main for the modes this
        // queue's work brings.
        d.setDispatchQueue(Self.queue)
        d.name = "Loom"
        d.maxPixelsWide = UInt32(Self.maxPixels)
        d.maxPixelsHigh = UInt32(Self.maxPixels)
        // About a 13-inch panel, so the system picks a sensible scale.
        d.sizeInMillimeters = CGSize(width: 300, height: 195)
        d.vendorID = Self.vendor
        d.productID = Self.product
        // Two serials in turn: one made to replace another is a second
        // display while both are up, not the same one again (which fails).
        Self.serial = Self.serial % 2 + 1
        d.serialNum = Self.serial
        guard let display = CGVirtualDisplay(descriptor: d) else { return nil }
        self.display = display
        size = (width, height)
        guard apply(width: width, height: height) else { return nil }
        log("made virtual display \(display.displayID), \(width)x\(height) points at 2x")
    }

    /// `width`×`height` points at 2×. False if the system would not have it.
    func resize(width: Int, height: Int) -> Bool {
        guard (width, height) != size else { return true }
        guard apply(width: width, height: height) else { return false }
        size = (width, height)
        log("virtual display \(display.displayID) now \(width)x\(height) points at 2x")
        return true
    }

    private func apply(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, width * 2 <= Self.maxPixels, height * 2 <= Self.maxPixels else { return false }
        let s = CGVirtualDisplaySettings()
        s.hiDPI = 1
        s.modes = [
            CGVirtualDisplayMode(width: UInt(width * 2), height: UInt(height * 2), refreshRate: 60),
            CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 60),
        ]
        // Now and then the modes given are never listed: given again.
        for _ in 0..<3 {
            guard display.apply(s) else { return false }
            if choose(width: width, height: height) { return true }
        }
        return false
    }

    /// Offering a 2× mode isn't using it: the system may pick the 1× one, or
    /// another it lists. Switch to the 2× one by name, once it is listed.
    private func choose(width: Int, height: Int) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        for _ in 0..<40 {
            let modes = (CGDisplayCopyAllDisplayModes(display.displayID, options) as? [CGDisplayMode]) ?? []
            if let mode = modes.first(where: { $0.width == width && $0.height == height && $0.pixelWidth == width * 2 }) {
                var config: CGDisplayConfigRef?
                guard CGBeginDisplayConfiguration(&config) == .success else { return false }
                CGConfigureDisplayWithDisplayMode(config, display.displayID, mode, nil)
                return CGCompleteDisplayConfiguration(config, .forSession) == .success
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let listed = ((CGDisplayCopyAllDisplayModes(display.displayID, options) as? [CGDisplayMode]) ?? [])
            .map { "\($0.width)x\($0.height)@\($0.pixelWidth)" }
        log("virtual display \(display.displayID): no \(width)x\(height) at 2x listed, only \(listed)")
        return false
    }

    /// The `others` showing what this one shows, this one the desktop. Undone
    /// by macOS when this one goes.
    func mirror(_ others: [CGDirectDisplayID]) {
        guard !others.isEmpty else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for other in others { CGConfigureDisplayMirrorOfDisplay(config, other, display.displayID) }
        let done = CGCompleteDisplayConfiguration(config, .forSession) == .success
        log("virtual display \(display.displayID) mirrored by \(others): \(done ? "ok" : "refused")")
    }

    deinit { log("virtual display \(display.displayID) gone") }
}
