import CoreMedia
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit

/// The main display through ScreenCaptureKit, into the encoder. ScreenCaptureKit
/// sends a frame only when something on screen changed, so an idle screen
/// costs nearly nothing; the last frame is kept to answer a keyframe request
/// while nothing moves.
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "capture", qos: .userInteractive)
    private(set) var displayID = CGMainDisplayID()
    private var stream: SCStream?
    private var display: SCDisplay?
    private var scale = 1
    /// The size a viewer asked the virtual display to be, in points.
    private var wanted: (width: Int, height: Int)?
    /// Whether a viewer has sent its settings: one that says no size wants none.
    private var told = false
    private var last: CVPixelBuffer?
    // While the Mac has no display of its own to show; see Virtual.swift.
    // Kept for the life of the process, which ends a while after the last
    // viewer: made and dropped per viewer, the one just dropped is still
    // listed for a moment, and capturing it fails.
    private var virtual: VirtualDisplay?
    // Held while capturing: see `awake()`.
    private var assertion: IOPMAssertionID = 0
    private var activity: IOPMAssertionID = 0
    private let encoder: Encoder
    private let onError: (String) -> Void

    init(encoder: Encoder, onError: @escaping (String) -> Void) {
        self.encoder = encoder
        self.onError = onError
    }

    func start() {
        awake()
        Task {
            do {
                guard let display = try await self.display() else {
                    onError("this Mac has no display to show, and making one failed")
                    return
                }
                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration(display), delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                queue.async {
                    self.display = display
                    self.displayID = display.displayID
                    self.stream = stream
                }
                log("capturing display \(display.displayID), \(display.width)x\(display.height) points")
            } catch {
                log("cannot capture: \(error)")
                onError("Screen Recording is not allowed for LoomMacScreen: on the Mac, System Settings → Privacy & Security → Screen & System Audio Recording (\(error.localizedDescription))")
            }
        }
    }

    func stop() {
        queue.async {
            let stream = self.stream
            self.stream = nil
            self.last = nil
            self.encoder.stop()
            for id in [self.assertion, self.activity] where id != 0 { IOPMAssertionRelease(id) }
            self.assertion = 0
            self.activity = 0
            Task { try? await stream?.stopCapture() }
        }
    }

    /// The Mac drawing its screen while someone watches. With the lid shut on
    /// AC it sits in a dark wake: awake, but with every display off and
    /// nothing composited, so there is no frame to capture. Declaring user
    /// activity brings it to a full wake, as a key press would; the display
    /// is then kept from sleeping until the last viewer goes.
    private func awake() {
        queue.async {
            // Declared again for each viewer, under the same id, so they do
            // not pile up; released with the other when the last one goes.
            IOPMAssertionDeclareUserActivity("Loom: someone is watching the screen" as CFString, kIOPMUserActiveLocal, &self.activity)
            guard self.assertion == 0 else { return }
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Loom: someone is watching the screen" as CFString, &self.assertion)
        }
    }

    /// The main display, or, with none to show (the lid shut), a virtual one
    /// made for the purpose, once WindowServer lists it. A display macOS
    /// made itself for a screen-sharing session on a headless Mac (vendor
    /// "unkn", product "virt", 1920×1080 at 1×) is not one to show: ours is
    /// made all the same, and that one set to mirror it, so the desktop and
    /// its windows are on ours, at the size a viewer asked for.
    private func display() async throws -> SCDisplay? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ours = await MainActor.run { self.virtual?.id }
        let real = content.displays.filter { $0.displayID != ours && !Self.madeByMacOS($0.displayID) && !Self.madeByUs($0.displayID) }
        if let d = real.first(where: { $0.displayID == CGMainDisplayID() }) ?? real.first {
            return d
        }
        // A viewer says its size just after it connects: made that size at
        // once, rather than made and then changed.
        for _ in 0..<15 where ours == nil && queue.sync(execute: { !self.told }) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let made: VirtualDisplay? = await MainActor.run {
            if self.virtual == nil {
                self.virtual = self.wanted.flatMap { VirtualDisplay(width: $0.width, height: $0.height) } ?? VirtualDisplay()
            }
            return self.virtual
        }
        guard let made else { return nil }
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let d = content.displays.first(where: { $0.displayID == made.id }) {
                await MainActor.run { made.mirror(content.displays.map(\.displayID).filter(Self.madeByMacOS)) }
                return d
            }
        }
        return nil
    }

    /// One of ours, the current one or one going away.
    private static func madeByUs(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == VirtualDisplay.vendor && CGDisplayModelNumber(id) == VirtualDisplay.product
    }

    private static func madeByMacOS(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 0x756e_6b6e && CGDisplayModelNumber(id) == 0x7669_7274  // "unkn", "virt"
    }

    func keyframe() {
        queue.async {
            self.encoder.requestKeyframe()
            if let last = self.last {
                self.encoder.encode(last, pts: CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }
    }

    func setScale(_ s: Int) {
        queue.async {
            self.told = true
            let s = s == 2 ? 2 : 1
            guard s != self.scale else { return }
            self.scale = s
            guard let stream = self.stream, let display = self.display else { return }
            stream.updateConfiguration(self.configuration(display)) { error in
                if let error { log("cannot rescale: \(error)") }
            }
        }
    }

    /// A viewer's own size for the virtual display, in pixels at 2×. Only a
    /// display made for the purpose changes; a real one stays as it is.
    func setSize(width: Int, height: Int) {
        queue.async {
            let points = (width: width / 2, height: height / 2)
            guard points.width > 0, points.height > 0 else { return }
            self.wanted = points
            Task { @MainActor in
                guard let virtual = self.virtual, self.displayID == virtual.id, virtual.size != points else { return }
                // Should it refuse the size, a new one that size, made before the old one
                // goes, or macOS makes its own 1920×1080 in between; failing that, the old one.
                if !virtual.resize(width: points.width, height: points.height) {
                    self.virtual = VirtualDisplay(width: points.width, height: points.height) ?? virtual
                }
                self.restart()
            }
        }
    }

    /// The stream again, on the display as it now is.
    private func restart() {
        queue.async {
            let stream = self.stream
            self.stream = nil
            Task {
                try? await stream?.stopCapture()
                self.start()
            }
        }
    }

    private func configuration(_ display: SCDisplay) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        // Even, as H.264 wants.
        c.width = display.width * scale / 2 * 2
        c.height = display.height * scale / 2 * 2
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.showsCursor = true
        c.queueDepth = 4
        return c
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sample.imageBuffer else { return }
        last = pixels
        encoder.encode(pixels, pts: sample.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("capture stopped: \(error)")
        queue.async { if self.stream === stream { self.stream = nil } }
        onError("the capture stopped: \(error.localizedDescription)")
    }
}
