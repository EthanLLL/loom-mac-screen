import Darwin
import Foundation

/// The viewers, each one TCP connection on loopback (loom-node's tunnel, or
/// its WebRTC bridge, is what dials in). Every viewer gets the same picture;
/// input from any of them is posted.
///
/// A viewer that can't keep up — frames queued beyond `behind` bytes — is
/// skipped until the next keyframe, which it is then sent: H.264 can't drop
/// a frame in the middle and decode what follows.
final class Server {
    final class Viewer {
        let fd: Int32
        let queue: DispatchQueue
        var queued = 0
        var waitingKey = true
        init(fd: Int32) {
            self.fd = fd
            queue = DispatchQueue(label: "viewer-\(fd)")
        }
    }

    private let lock = NSLock()
    private var viewers: [Int32: Viewer] = [:]
    private let behind = 4 << 20

    var onFirst: () -> Void = {}
    var onLast: () -> Void = {}
    var onKeyframe: () -> Void = {}
    var onInput: (Data) -> Void = { _ in }
    var onSettings: (Data) -> Void = { _ in }

    var count: Int { lock.withLock { viewers.count } }

    /// Accepts on `listener` for good, each viewer on its own thread.
    func serve(_ listener: Int32) {
        Thread.detachNewThread {
            while true {
                let fd = accept(listener, nil, nil)
                if fd < 0 {
                    if errno == EINTR { continue }
                    log("accept: \(String(cString: strerror(errno)))")
                    return
                }
                var one: Int32 = 1
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                self.add(Viewer(fd: fd))
            }
        }
    }

    private func add(_ v: Viewer) {
        let first = lock.withLock {
            viewers[v.fd] = v
            return viewers.count == 1
        }
        log("viewer \(v.fd) connected")
        if first { onFirst() }
        onKeyframe()
        Thread.detachNewThread { self.read(v) }
    }

    private func drop(_ v: Viewer) {
        // From the reader and a failed write alike; only the first closes,
        // or a second close could hit the next viewer given the same number.
        let (removed, last) = lock.withLock { () -> (Bool, Bool) in
            guard viewers.removeValue(forKey: v.fd) != nil else { return (false, false) }
            return (true, viewers.isEmpty)
        }
        guard removed else { return }
        shutdown(v.fd, SHUT_RDWR)
        v.queue.async { close(v.fd) }
        log("viewer \(v.fd) gone")
        if last { onLast() }
    }

    private func read(_ v: Viewer) {
        var header = [UInt8](repeating: 0, count: 5)
        while readFull(v.fd, &header, 5) {
            let n = Int(header[1]) << 24 | Int(header[2]) << 16 | Int(header[3]) << 8 | Int(header[4])
            guard n <= Wire.maxIncoming else { break }
            var body = [UInt8](repeating: 0, count: n)
            if n > 0, !readFull(v.fd, &body, n) { break }
            let data = Data(body)
            switch header[0] {
            case Wire.input: onInput(data)
            case Wire.keyframe: onKeyframe()
            case Wire.settings: onSettings(data)
            default: break
            }
        }
        drop(v)
    }

    private func readFull(_ fd: Int32, _ buf: inout [UInt8], _ n: Int) -> Bool {
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, n - got, 0) }
            if r > 0 { got += r } else if r < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }

    /// To every viewer that can take it.
    func send(frame: Encoder.Frame) {
        var payload = Data(capacity: 9 + frame.annexB.count)
        payload.append(frame.key ? 1 : 0)
        withUnsafeBytes(of: frame.pts.bigEndian) { payload.append(contentsOf: $0) }
        payload.append(frame.annexB)
        var message = Data()
        if frame.key, let codec = frame.codec {
            message.append(Wire.json(Wire.config, ["codec": codec, "width": frame.width, "height": frame.height]))
        }
        message.append(Wire.message(Wire.frame, payload))

        var lagging = false
        for v in lock.withLock({ Array(viewers.values) }) {
            let skip: Bool = lock.withLock {
                if v.waitingKey && !frame.key { return true }
                if v.queued > behind {
                    v.waitingKey = true
                    lagging = true
                    return true
                }
                v.waitingKey = false
                return false
            }
            if skip { continue }
            write(v, message)
        }
        if lagging { onKeyframe() }
    }

    func send(error message: String) {
        let data = Wire.json(Wire.error, ["message": message])
        for v in lock.withLock({ Array(viewers.values) }) { write(v, data) }
    }

    private func write(_ v: Viewer, _ data: Data) {
        lock.withLock { v.queued += data.count }
        v.queue.async {
            let ok = data.withUnsafeBytes { raw -> Bool in
                var sent = 0
                while sent < data.count {
                    let r = Darwin.send(v.fd, raw.baseAddress! + sent, data.count - sent, 0)
                    if r > 0 { sent += r } else if r < 0 && errno == EINTR { continue } else { return false }
                }
                return true
            }
            self.lock.withLock { v.queued -= data.count }
            if !ok { self.drop(v) }
        }
    }
}
