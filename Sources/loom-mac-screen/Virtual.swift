import CGVirtualDisplay
import Foundation

/// A display for a Mac that has none to show: its lid shut and nothing
/// plugged in, so the built-in screen sleeps and ScreenCaptureKit finds no
/// display. Made while someone is watching and gone with the last viewer
/// (when this is released), so the Mac is otherwise as it was.
///
/// The size is an M2 Air's default, 1470×956 points at 2×.
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    var id: CGDirectDisplayID { display.displayID }

    init?(width: Int = 1470, height: Int = 956) {
        let d = CGVirtualDisplayDescriptor()
        d.setDispatchQueue(DispatchQueue.main)
        d.name = "Loom"
        d.maxPixelsWide = UInt32(width * 2)
        d.maxPixelsHigh = UInt32(height * 2)
        // About a 13-inch panel, so the system picks a sensible scale.
        d.sizeInMillimeters = CGSize(width: 300, height: 195)
        d.vendorID = 0x4C4D
        d.productID = 0x5343
        d.serialNum = 1
        guard let display = CGVirtualDisplay(descriptor: d) else { return nil }
        let s = CGVirtualDisplaySettings()
        s.hiDPI = 1
        s.modes = [
            CGVirtualDisplayMode(width: UInt(width * 2), height: UInt(height * 2), refreshRate: 60),
            CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 60),
        ]
        guard display.apply(s) else { return nil }
        self.display = display
        log("made virtual display \(display.displayID)")
    }

    deinit { log("virtual display \(display.displayID) gone") }
}
