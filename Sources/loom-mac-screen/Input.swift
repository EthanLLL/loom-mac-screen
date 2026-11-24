import ApplicationServices
import Foundation

/// The viewer's mouse and keys, posted as if from this Mac's own. Needs
/// Accessibility for LoomMacScreen.
///
///   {"t":"move", "x":0.5, "y":0.5}         x, y: 0…1 across the picture
///   {"t":"down"|"up", "x", "y", "b":0}     b: 0 left, 1 middle, 2 right (as the DOM's)
///   {"t":"wheel", "dx":0, "dy":-40}        pixels, the DOM's sign
///   {"t":"key", "code":"KeyA", "down":true} the DOM's KeyboardEvent.code
///   {"t":"release"}                         let go of every key and button held
///
/// The keys are positions, not characters: the Mac's own input source turns
/// them into text, so Pinyin works as it does at its keyboard.
final class Input {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var flags: CGEventFlags = []
    private var held: Set<CGKeyCode> = []
    private var buttons: Set<Int> = []
    private var lastDown = (time: 0.0, point: CGPoint.zero, button: -1, clicks: 0)
    private let display: () -> CGDirectDisplayID

    init(display: @escaping () -> CGDirectDisplayID) {
        self.display = display
    }

    func handle(_ data: Data) {
        guard let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let t = m["t"] as? String else { return }
        switch t {
        case "move":
            if let p = point(m) { mouse(dragType() ?? .mouseMoved, p, button: dragButton()) }
        case "down", "up":
            guard let p = point(m) else { return }
            let b = m["b"] as? Int ?? 0
            button(b, down: t == "down", at: p)
        case "wheel":
            let dx = m["dx"] as? Double ?? 0, dy = m["dy"] as? Double ?? 0
            if let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                               wheel1: Int32((-dy).rounded()), wheel2: Int32((-dx).rounded()), wheel3: 0) {
                e.flags = flags
                e.post(tap: .cghidEventTap)
            }
        case "key":
            guard let code = m["code"] as? String, let key = Input.keys[code] else { return }
            self.key(key, down: m["down"] as? Bool ?? true)
        case "release":
            releaseAll()
        default:
            break
        }
    }

    func releaseAll() {
        for k in held { key(k, down: false) }
        let at = CGEvent(source: nil)?.location ?? .zero
        for b in buttons { button(b, down: false, at: at) }
    }

    private func point(_ m: [String: Any]) -> CGPoint? {
        guard let x = m["x"] as? Double, let y = m["y"] as? Double else { return nil }
        let bounds = CGDisplayBounds(display())
        return CGPoint(x: bounds.minX + min(max(x, 0), 1) * bounds.width,
                       y: bounds.minY + min(max(y, 0), 1) * bounds.height)
    }

    private func dragButton() -> CGMouseButton {
        buttons.contains(0) ? .left : buttons.contains(2) ? .right : .center
    }

    private func dragType() -> CGEventType? {
        if buttons.contains(0) { return .leftMouseDragged }
        if buttons.contains(2) { return .rightMouseDragged }
        if !buttons.isEmpty { return .otherMouseDragged }
        return nil
    }

    private func button(_ b: Int, down: Bool, at p: CGPoint) {
        let (type, cg): (CGEventType, CGMouseButton) = switch b {
        case 2: (down ? .rightMouseDown : .rightMouseUp, .right)
        case 1: (down ? .otherMouseDown : .otherMouseUp, .center)
        default: (down ? .leftMouseDown : .leftMouseUp, .left)
        }
        if down {
            buttons.insert(b)
            // A double click is two downs close in time and place; the Mac
            // counts them only when told.
            let now = Date().timeIntervalSince1970
            let near = abs(p.x - lastDown.point.x) < 5 && abs(p.y - lastDown.point.y) < 5
            let clicks = (now - lastDown.time < 0.4 && near && lastDown.button == b) ? lastDown.clicks + 1 : 1
            lastDown = (now, p, b, clicks)
        } else {
            buttons.remove(b)
        }
        mouse(type, p, button: cg, clicks: lastDown.button == b ? lastDown.clicks : 1)
    }

    private func mouse(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton, clicks: Int = 1) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private func key(_ code: CGKeyCode, down: Bool) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        if down { held.insert(code) } else { held.remove(code) }
        if let flag = Input.modifiers[code] {
            if down { flags.insert(flag) } else { flags.remove(flag) }
            e.type = .flagsChanged
        }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private static let modifiers: [CGKeyCode: CGEventFlags] = [
        0x38: .maskShift, 0x3C: .maskShift,
        0x3B: .maskControl, 0x3E: .maskControl,
        0x3A: .maskAlternate, 0x3D: .maskAlternate,
        0x37: .maskCommand, 0x36: .maskCommand,
        0x39: .maskAlphaShift, 0x3F: .maskSecondaryFn,
    ]

    // KeyboardEvent.code → macOS virtual key code (HIToolbox's kVK_*).
    private static let keys: [String: CGKeyCode] = [
        "KeyA": 0x00, "KeyS": 0x01, "KeyD": 0x02, "KeyF": 0x03, "KeyH": 0x04, "KeyG": 0x05, "KeyZ": 0x06,
        "KeyX": 0x07, "KeyC": 0x08, "KeyV": 0x09, "IntlBackslash": 0x0A, "KeyB": 0x0B, "KeyQ": 0x0C,
        "KeyW": 0x0D, "KeyE": 0x0E, "KeyR": 0x0F, "KeyY": 0x10, "KeyT": 0x11, "Digit1": 0x12,
        "Digit2": 0x13, "Digit3": 0x14, "Digit4": 0x15, "Digit6": 0x16, "Digit5": 0x17, "Equal": 0x18,
        "Digit9": 0x19, "Digit7": 0x1A, "Minus": 0x1B, "Digit8": 0x1C, "Digit0": 0x1D,
        "BracketRight": 0x1E, "KeyO": 0x1F, "KeyU": 0x20, "BracketLeft": 0x21, "KeyI": 0x22, "KeyP": 0x23,
        "Enter": 0x24, "KeyL": 0x25, "KeyJ": 0x26, "Quote": 0x27, "KeyK": 0x28, "Semicolon": 0x29,
        "Backslash": 0x2A, "Comma": 0x2B, "Slash": 0x2C, "KeyN": 0x2D, "KeyM": 0x2E, "Period": 0x2F,
        "Tab": 0x30, "Space": 0x31, "Backquote": 0x32, "Backspace": 0x33, "Escape": 0x35,
        "MetaRight": 0x36, "MetaLeft": 0x37, "ShiftLeft": 0x38, "CapsLock": 0x39, "AltLeft": 0x3A,
        "ControlLeft": 0x3B, "ShiftRight": 0x3C, "AltRight": 0x3D, "ControlRight": 0x3E, "Fn": 0x3F,
        "F17": 0x40, "NumpadDecimal": 0x41, "NumpadMultiply": 0x43, "NumpadAdd": 0x45,
        "NumLock": 0x47, "NumpadDivide": 0x4B, "NumpadEnter": 0x4C, "NumpadSubtract": 0x4E,
        "F18": 0x4F, "F19": 0x50, "NumpadEqual": 0x51, "Numpad0": 0x52, "Numpad1": 0x53,
        "Numpad2": 0x54, "Numpad3": 0x55, "Numpad4": 0x56, "Numpad5": 0x57, "Numpad6": 0x58,
        "Numpad7": 0x59, "F20": 0x5A, "Numpad8": 0x5B, "Numpad9": 0x5C, "IntlYen": 0x5D,
        "IntlRo": 0x5E, "NumpadComma": 0x5F, "F5": 0x60, "F6": 0x61, "F7": 0x62, "F3": 0x63,
        "F8": 0x64, "F9": 0x65, "Lang2": 0x66, "F11": 0x67, "Lang1": 0x68, "F13": 0x69, "F16": 0x6A,
        "F14": 0x6B, "F10": 0x6D, "ContextMenu": 0x6E, "F12": 0x6F, "F15": 0x71, "Help": 0x72,
        "Insert": 0x72, "Home": 0x73, "PageUp": 0x74, "Delete": 0x75, "F4": 0x76, "End": 0x77,
        "F2": 0x78, "PageDown": 0x79, "F1": 0x7A, "ArrowLeft": 0x7B, "ArrowRight": 0x7C,
        "ArrowDown": 0x7D, "ArrowUp": 0x7E,
    ]
}
