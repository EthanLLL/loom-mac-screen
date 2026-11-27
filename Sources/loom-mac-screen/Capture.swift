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
    /// What the line to the viewer carries, as the viewer tells it (Wire.swift):
    /// each a ladder of fixed steps, gone down one at a time when a viewer
    /// falls behind and never back up for it. A fixed rate below the line's
    /// capacity plays smoothly; one chasing the line stalls each time it
    /// falls behind. Sharp is the viewer's own pixels (2× for one that
    /// doesn't say), otherwise a pixel a point.
    enum Line: String {
        /// The Mac's own network.
        case lan
        /// Straight across the internet, or through a TURN relay.
        case wan
        /// Round by the Loom, or a viewer that never says.
        case narrow

        var steps: [Step] {
            switch self {
            case .lan: [Step(12_000_000, 60, sharp: true), Step(6_000_000, 30, sharp: true), Step(3_000_000, 30, sharp: true), Step(1_500_000, 30, sharp: true)]
            case .wan: [Step(3_000_000, 30, sharp: true), Step(1_500_000, 30, sharp: false)]
            case .narrow: [Step(1_500_000, 30, sharp: false)]
            }
        }
    }

    struct Step: Equatable {
        let rate: Int
        let fps: Int32
        let sharp: Bool
        init(_ rate: Int, _ fps: Int32, sharp: Bool) {
            self.rate = rate
            self.fps = fps
            self.sharp = sharp
        }
    }

    private var line = Line.narrow
    private var level = 0
    private var step: Step { line.steps[level] }
    private var lastStep = Date.distantPast
    /// When the viewer last fell behind without it counting yet: a step down
    /// takes a second fall, so a single stall (the line moving from a relay
    /// to a direct path as ICE finds a better one) costs nothing for good.
    private var lastFall: Date?
    /// The viewer's pixels for the virtual display, and the points it is
    /// laid out in: 1.5 pixels a point, so the Mac lays out about as on a
    /// laptop rather than a tablet (on the Duo's upper half 1252×889 points,
    /// not 939×667, at which pages took their narrow layouts).
    private var asked: (width: Int, height: Int)?
    private var wanted: (width: Int, height: Int)?
    /// Whether a viewer has sent its settings: one that says no size wants none.
    private var told = false
    private var last: CVPixelBuffer?
    /// Which start is the current one: a stop, or a start begun again,
    /// supersedes it, and a stream it still brings up is stopped at once.
    private var generation = 0
    /// The start each stream was made for: a frame from one whose start is
    /// no longer current stops it (a stop that missed it, or a stream
    /// that came up after it).
    private var made: [ObjectIdentifier: Int] = [:]
    /// What came out of the display lately, logged every few seconds.
    private var tally = (frames: 0, luma: 0, since: Date())
    // While the Mac has no display of its own to show; see Virtual.swift.
    // One for the life of the process, which ends five seconds after the
    // last viewer (main.swift), taking it with it: one dropped and made
    // again in the same process lists no modes, however long after. macOS
    // takes it away in its own time, and one made while it is still
    // listed gets none either, so a new process waits for it to go: never
    // two of ours at once.
    private var virtual: VirtualDisplay?
    // Held while capturing: see `awake()`.
    private var assertion: IOPMAssertionID = 0
    private var activity: IOPMAssertionID = 0
    private let encoder: Encoder
    /// What the server did with the frames, for the log.
    var report: () -> String = { "" }
    private let onError: (String) -> Void

    init(encoder: Encoder, onError: @escaping (String) -> Void) {
        self.encoder = encoder
        self.onError = onError
    }

    /// Tried again, a second apart, up to three times: just after the Mac
    /// wakes, the display it shows can be listed yet refuse a stream.
    func start(attempt: Int = 1) {
        awake()
        let mine = queue.sync { generation += 1; return generation }
        Task {
            do {
                guard let display = try await self.display() else {
                    onError("this Mac has no display to show, and making one failed")
                    return
                }
                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration(display), delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                queue.sync { self.made[ObjectIdentifier(stream)] = mine }
                try await stream.startCapture()
                // A viewer that came and went at once, its start overtaken by the next one's.
                guard queue.sync(execute: { self.generation == mine }) else {
                    try? await stream.stopCapture()
                    log("dropped a stream started for a viewer since gone")
                    return
                }
                queue.async {
                    self.display = display
                    self.displayID = display.displayID
                    self.stream = stream
                    // A size asked for while this start was under way, for a display
                    // made before it (by a viewer that left at once), applies now.
                    if let a = self.asked { self.setSize(width: a.width, height: a.height) }
                }
                log("capturing display \(display.displayID) (vendor \(String(CGDisplayVendorNumber(display.displayID), radix: 16))), \(display.width)x\(display.height) points")
            } catch {
                log("cannot capture: \(error)")
                if attempt < 3, queue.sync(execute: { self.generation == mine }) {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if queue.sync(execute: { self.generation == mine }) { self.start(attempt: attempt + 1) }
                    return
                }
                onError("Screen Recording is not allowed for LoomMacScreen: on the Mac, System Settings → Privacy & Security → Screen & System Audio Recording (\(error.localizedDescription))")
            }
        }
    }

    func stop() {
        queue.async {
            self.generation += 1
            self.told = false
            self.line = .narrow
            self.level = 0
            self.lastFall = nil
            self.encoder.setBitrate(self.step.rate)
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
        // A viewer says its size and line just after it connects: a display
        // made that size, and a stream begun as it should be, rather than
        // either changed at once (a still screen sends nothing after a
        // change, so the viewer would wait for a frame that never comes).
        for _ in 0..<15 where queue.sync(execute: { !self.told }) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ours = await MainActor.run { self.virtual?.id }
        // A display macOS has only just made can say vendor 0 for a moment.
        let real = content.displays.filter {
            $0.displayID != ours && !Self.madeByMacOS($0.displayID) && !Self.madeByUs($0.displayID)
                && (CGDisplayIsBuiltin($0.displayID) != 0 || CGDisplayVendorNumber($0.displayID) != 0)
        }
        if let d = real.first(where: { $0.displayID == CGMainDisplayID() }) ?? real.first {
            return d
        }
        if await MainActor.run(body: { self.virtual == nil }) {
            for i in 0..<50 where Self.anyOfOurs() {
                if i == 0 { log("waiting for the last virtual display to go") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
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

    /// Whether macOS still lists a display of ours.
    private static func anyOfOurs() -> Bool {
        var n: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetOnlineDisplayList(n, &ids, &n)
        return ids.prefix(Int(n)).contains(where: madeByUs)
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

    /// The viewer's line; see `Line`.
    func setLine(_ l: Line) {
        queue.async {
            self.told = true
            guard l != self.line else { return }
            self.line = l
            self.level = 0
            self.lastFall = nil
            self.encoder.setBitrate(self.step.rate)
            log("line \(l): \(self.describe(self.step))")
            self.refit()
        }
    }

    private func describe(_ s: Step) -> String {
        "\(Double(s.rate) / 1e6) Mbps, \(s.fps) frames/s, \(s.sharp ? "sharp" : "a pixel a point")"
    }

    /// A viewer's own size for the virtual display, in its pixels. Only a
    /// display made for the purpose changes; a real one stays as it is.
    func setSize(width: Int, height: Int) {
        queue.async {
            let points = (width: width * 2 / 3, height: height * 2 / 3)
            guard points.width > 0, points.height > 0 else { return }
            self.asked = (width, height)
            self.wanted = points
            Task { @MainActor in
                guard let virtual = self.virtual, self.displayID == virtual.id, virtual.size != points else { return }
                // Refused, it stays as it is (never a second one beside it), and the next size tries again.
                guard virtual.resize(width: points.width, height: points.height) else {
                    log("virtual display \(virtual.id) stays \(virtual.size.width)x\(virtual.size.height)")
                    return
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

    /// A viewer fell behind: the line's next step down, if it has one, on the
    /// second fall within half a minute (each at least four seconds after the
    /// one before and after the last step, while what was queued drains).
    func behind() {
        queue.async {
            let now = Date()
            guard self.level < self.line.steps.count - 1, now.timeIntervalSince(self.lastStep) >= 4 else { return }
            guard let fall = self.lastFall, (4...30).contains(now.timeIntervalSince(fall)) else {
                if self.lastFall.map({ now.timeIntervalSince($0) >= 4 }) ?? true { self.lastFall = now }
                log("viewer fell behind; the next fall within 30 s steps down")
                return
            }
            self.lastFall = nil
            let was = self.step
            self.level += 1
            self.lastStep = Date()
            self.encoder.setBitrate(self.step.rate)
            log("encoder now \(self.describe(self.step))")
            if self.step.fps != was.fps || self.step.sharp != was.sharp { self.refit() }
        }
    }

    /// The stream's size and frame rate as they now should be. On the queue.
    private func refit() {
        guard let stream, let display else { return }
        stream.updateConfiguration(configuration(display)) { error in
            if let error { log("cannot change the stream: \(error)") }
        }
    }

    private func configuration(_ display: SCDisplay) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        // Sharp, ours at the viewer's own pixels (macOS draws it at 2× and
        // scales down), any other at 2×; otherwise a pixel a point. Even, as
        // H.264 wants.
        let step = self.step
        var size = step.sharp ? (display.width * 2, display.height * 2) : (display.width, display.height)
        if step.sharp, let asked, Self.madeByUs(display.displayID) { size = asked }
        c.width = size.0 / 2 * 2
        c.height = size.1 / 2 * 2
        c.minimumFrameInterval = CMTime(value: 1, timescale: step.fps)
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.showsCursor = true
        c.queueDepth = 4
        return c
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        if let g = made[ObjectIdentifier(stream)], g != generation {
            made[ObjectIdentifier(stream)] = nil
            log("stopping a stream left running")
            Task { try? await stream.stopCapture() }
            return
        }
        guard type == .screen, sample.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sample.imageBuffer else { return }
        last = pixels
        count(pixels)
        encoder.encode(pixels, pts: sample.presentationTimeStamp)
    }

    /// Frames a second and their mean brightness (0–255, from a grid of the
    /// luma plane), every five seconds: a black screen tells on itself here.
    private func count(_ pixels: CVPixelBuffer) {
        tally.frames += 1
        if tally.frames % 10 == 1 {
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            if let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) {
                let w = CVPixelBufferGetWidthOfPlane(pixels, 0), h = CVPixelBufferGetHeightOfPlane(pixels, 0)
                let row = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
                let y = base.assumingMemoryBound(to: UInt8.self)
                var sum = 0
                for i in 1...16 { for j in 1...16 { sum += Int(y[h * i / 17 * row + w * j / 17]) } }
                tally.luma = sum / 256
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        let elapsed = Date().timeIntervalSince(tally.since)
        guard elapsed >= 5 else { return }
        log("display \(displayID): \(Int(Double(tally.frames) / elapsed)) frames/s, luma \(tally.luma), \(CVPixelBufferGetWidth(pixels))x\(CVPixelBufferGetHeight(pixels)); encoder \(encoder.tally()) at \(Double(encoder.bitrate) / 1e6) Mbps; \(report())")
        tally = (0, tally.luma, Date())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("capture stopped: \(error)")
        queue.async { if self.stream === stream { self.stream = nil } }
        onError("the capture stopped: \(error.localizedDescription)")
    }
}
