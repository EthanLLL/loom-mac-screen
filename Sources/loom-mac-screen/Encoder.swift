import CoreMedia
import Foundation
import VideoToolbox

/// H.264 from the hardware encoder, set for a screen being driven: real time,
/// low-latency rate control, no frame reordering, a keyframe only when a
/// viewer asks for one (a static screen sends almost nothing).
///
/// Used from one queue only, the capture's.
final class Encoder {
    struct Frame {
        let annexB: Data
        let key: Bool
        let pts: Int64 // µs
        let codec: String? // with a keyframe: "avc1.PPCCLL", for WebCodecs
        let width: Int
        let height: Int
    }

    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var forceKey = true
    private(set) var bitrate: Int
    /// Frames out, and the last failure, since the capture last logged them.
    private let counts = NSLock()
    private var out = (frames: 0, keys: 0, failed: OSStatus(0))
    private let onFrame: (Frame) -> Void

    init(bitrate: Int = 1_500_000, onFrame: @escaping (Frame) -> Void) {
        self.bitrate = bitrate
        self.onFrame = onFrame
    }

    func requestKeyframe() { forceKey = true }

    /// A new average rate, from the next frame on.
    func setBitrate(_ b: Int) {
        bitrate = b
        if let session { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: b as CFNumber) }
    }

    func encode(_ pixels: CVPixelBuffer, pts: CMTime) {
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        if session == nil || w != width || h != height {
            guard make(width: w, height: h) else { return }
        }
        guard let session else { return }

        var props: CFDictionary?
        if forceKey {
            forceKey = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
        }
        let (fw, fh) = (w, h)
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [self] status, _, sample in
            guard status == noErr, let sample, let frame = Encoder.annexB(sample, width: fw, height: fh) else {
                counts.withLock { out.failed = status == noErr ? -1 : status }
                return
            }
            counts.withLock { out.frames += 1; if frame.key { out.keys += 1 } }
            onFrame(frame)
        }
    }

    /// "N out (K keys)", and the last failure if any, counted afresh.
    func tally() -> String {
        counts.withLock {
            defer { out = (0, 0, 0) }
            return "\(out.frames) out (\(out.keys) keys)" + (out.failed != 0 ? ", failed \(out.failed)" : "")
        }
    }

    func stop() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    private func make(width w: Int, height h: Int) -> Bool {
        stop()
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!] as CFDictionary
        var made: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        guard status == noErr, let made else {
            log("cannot make an H.264 encoder for \(w)x\(h): \(status)")
            return false
        }
        let set = { (key: CFString, value: CFTypeRef) in VTSessionSetProperty(made, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber)
        // Keyframes come when asked for; this is only a backstop.
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 60 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(made)

        session = made
        width = w
        height = h
        forceKey = true
        log("encoding \(w)x\(h) H.264")
        return true
    }

    /// The sample's NAL units with start codes instead of lengths, the
    /// parameter sets first on a keyframe: what a decoder given no
    /// description expects.
    private static func annexB(_ sample: CMSampleBuffer, width: Int, height: Int) -> Frame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let start: [UInt8] = [0, 0, 0, 1]

        var out = Data()
        var codec: String?
        if key, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                guard let p else { continue }
                if i == 0, size >= 4 { codec = String(format: "avc1.%02x%02x%02x", p[1], p[2], p[3]) }
                out.append(contentsOf: start)
                out.append(p, count: size)
            }
        }

        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= length {
            let n = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard n > 0, offset + n <= length else { break }
            out.append(contentsOf: start)
            out.append(bytes + offset, count: n)
            offset += n
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let us = pts.isValid ? Int64(CMTimeGetSeconds(pts) * 1_000_000) : 0
        return Frame(annexB: out, key: key, pts: us, codec: codec, width: width, height: height)
    }
}
