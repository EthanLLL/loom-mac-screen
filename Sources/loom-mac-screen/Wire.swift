import Foundation

// What goes over the connection, both ways: one byte of type, four of length
// (big-endian), then the payload.
//
//   screen → viewer
//     1 config   JSON {codec, width, height}: before every keyframe
//     2 frame    1 byte flags (1 = keyframe), 8 bytes pts in µs, H.264 Annex B
//     3 error    JSON {message}: why there is no picture
//   viewer → screen
//     10 input     JSON, see Input.swift
//     11 keyframe  empty: the viewer has lost its place
//     12 settings  JSON {narrow?, width?, height?}: narrow false only on
//                  the Mac's own network (its pixels, 12 Mbit/s; otherwise
//                  a pixel a point, 1.5 Mbit/s); width and height, the
//                  viewer's pixels, which a virtual display (lid shut) is
//                  laid out at 1.5 a point
enum Wire {
    static let config: UInt8 = 1
    static let frame: UInt8 = 2
    static let error: UInt8 = 3
    static let input: UInt8 = 10
    static let keyframe: UInt8 = 11
    static let settings: UInt8 = 12

    // A viewer sends a few hundred bytes at a time; anything near this is not one.
    static let maxIncoming = 64 << 10

    static func message(_ type: UInt8, _ payload: Data) -> Data {
        var out = Data(capacity: 5 + payload.count)
        out.append(type)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    static func json(_ type: UInt8, _ object: [String: Any]) -> Data {
        message(type, (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
}
