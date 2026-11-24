import CoreMedia
import Foundation
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
    private var last: CVPixelBuffer?
    private let encoder: Encoder
    private let onError: (String) -> Void

    init(encoder: Encoder, onError: @escaping (String) -> Void) {
        self.encoder = encoder
        self.onError = onError
    }

    func start() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                    onError("this Mac has no display to show")
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
            Task { try? await stream?.stopCapture() }
        }
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
            let s = s == 2 ? 2 : 1
            guard s != self.scale else { return }
            self.scale = s
            guard let stream = self.stream, let display = self.display else { return }
            stream.updateConfiguration(self.configuration(display)) { error in
                if let error { log("cannot rescale: \(error)") }
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
