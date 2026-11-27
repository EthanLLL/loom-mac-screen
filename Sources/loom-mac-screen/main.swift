import ApplicationServices
import Darwin
import Foundation

// loom-mac-screen: this Mac's screen as H.264, and its mouse and keyboard, on
// one TCP port on loopback, for Loom's Connect. Loom reaches the port through
// loom-node — directly over WebRTC when the networks allow, relayed by Loom
// otherwise — and knows nothing about video; the page decodes it with
// WebCodecs. The protocol is in Wire.swift.
//
// Started by launchd when something connects (the LaunchAgent's Sockets, see
// install.sh), so it holds no permission prompt or capture open while unused,
// and gone again a while after the last viewer leaves. Launched by launchd from
// a signed app, Screen Recording and Accessibility are its own, granted once.
//
//   loom-mac-screen                launchd's socket "Listeners"
//   loom-mac-screen --listen 5960  its own, to try it by hand

let port: UInt16 = 5960
// Soon after the last viewer: ending is what takes the virtual display away (Capture.swift).
let idleExit: TimeInterval = 5

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(Date()) \(message)\n".utf8))
}

@_silgen_name("launch_activate_socket")
func launchActivateSocket(_ name: UnsafePointer<CChar>, _ fds: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>, _ count: UnsafeMutablePointer<Int>) -> Int32

func launchdListeners() -> [Int32] {
    var fds: UnsafeMutablePointer<Int32>?
    var count = 0
    guard launchActivateSocket("Listeners", &fds, &count) == 0, let fds else { return [] }
    defer { free(fds) }
    return (0..<count).map { fds[$0] }
}

func listen(on port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, Darwin.listen(fd, 8) == 0 else {
        log("cannot listen on 127.0.0.1:\(port): \(String(cString: strerror(errno)))")
        exit(1)
    }
    return fd
}

signal(SIGPIPE, SIG_IGN)

let args = CommandLine.arguments
let byHand = args.count == 3 && args[1] == "--listen"
let listeners = byHand ? [listen(on: UInt16(args[2]) ?? port)] : launchdListeners()
guard !listeners.isEmpty else {
    log("no socket from launchd; run with --listen PORT to try it by hand")
    exit(1)
}

// Asked once, at the first launch; macOS remembers the answer for this app.
if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
    log("Accessibility is not allowed yet: the mouse and keyboard won't reach this Mac")
}

let server = Server()
let encoder = Encoder { server.send(frame: $0) }
let capture = Capture(encoder: encoder) { server.send(error: $0) }
capture.report = { server.tally() }
let input = Input { capture.displayID }
let inputQueue = DispatchQueue(label: "input", qos: .userInteractive)

server.onFirst = { capture.start() }
server.onKeyframe = { capture.keyframe() }
server.onBehind = { capture.behind() }
server.onInput = { data in inputQueue.async { input.handle(data) } }
server.onSettings = { data in
    guard let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
    // Narrow unless a viewer says otherwise; viewers before "line" said
    // `narrow: false` on the Mac's own network.
    let line = (m["line"] as? String).flatMap(Capture.Line.init(rawValue:))
    capture.setLine(line ?? (m["narrow"] as? Bool == false ? .lan : .narrow))
    if let w = m["width"] as? Int, let h = m["height"] as? Int { capture.setSize(width: w, height: h) }
}
server.onLast = {
    capture.stop()
    inputQueue.async { input.releaseAll() }
    guard !byHand else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + idleExit) {
        if server.count == 0 {
            log("no viewers for \(Int(idleExit))s; exiting")
            exit(0)
        }
    }
}

for fd in listeners { server.serve(fd) }
log("loom-mac-screen ready")
dispatchMain()
