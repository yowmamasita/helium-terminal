import AppKit
import Carbon
import GhosttyKit

// Keyboard, IME and mouse handling adapted from Ghostty's SurfaceView_AppKit.swift
// (MIT, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors).

/// One terminal: an NSView that libghostty renders into with Metal.
final class SurfaceView: NSView, NSTextInputClient {
    private static var nextID = 1

    let id: Int
    private(set) var surface: ghostty_surface_t?
    var title = ""
    var pwd: String?
    weak var pane: PaneView?

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var cursor: NSCursor = .iBeam
    private var trackingArea: NSTrackingArea?

    static func from(_ ud: UnsafeMutableRawPointer?) -> SurfaceView? {
        ud.map { Unmanaged<SurfaceView>.fromOpaque($0).takeUnretainedValue() }
    }

    init(app: ghostty_app_t, workingDirectory: String?, command: String? = nil, fontSize: Float = 0) {
        id = Self.nextID
        Self.nextID += 1
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.font_size = fontSize
        cfg.context = GHOSTTY_SURFACE_CONTEXT_TAB

        // HELIUM_PANE lets `helium notify` inside this pane target itself.
        let env: [(String, String)] = [("HELIUM_PANE", "\(id)"), ("HELIUM_SOCKET", SocketServer.path)]
        let cStrings = env.flatMap { [strdup($0.0)!, strdup($0.1)!] }
        defer { cStrings.forEach { free($0) } }
        var vars = (0..<env.count).map { ghostty_env_var_s(key: cStrings[$0 * 2], value: cStrings[$0 * 2 + 1]) }

        let wd = workingDirectory.flatMap { strdup($0) }
        let cmd = command.flatMap { strdup($0) }
        defer { free(wd); free(cmd) }
        cfg.working_directory = UnsafePointer(wd)
        cfg.command = UnsafePointer(cmd)

        surface = vars.withUnsafeMutableBufferPointer { buf in
            cfg.env_vars = buf.baseAddress
            cfg.env_var_count = buf.count
            return ghostty_surface_new(app, &cfg)
        }
        pwd = workingDirectory
        syncFocus()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Frees the libghostty surface. Called once when the pane closes.
    func destroy() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    /// Working directory to hand to a new tab or split opened from this one.
    var inheritedWorkingDirectory: String? {
        guard let surface else { return pwd }
        let cfg = ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_SPLIT)
        return cfg.working_directory.map { String(cString: $0) } ?? pwd
    }

    var ttyName: String? {
        guard let surface else { return nil }
        let s = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(s) }
        guard let p = s.ptr, s.len > 0 else { return nil }
        return String(data: Data(bytes: p, count: Int(s.len)), encoding: .utf8)
    }

    var foregroundPID: pid_t {
        surface.map { pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid($0)) } ?? 0
    }

    var needsConfirmQuit: Bool { surface.map { ghostty_surface_needs_confirm_quit($0) } ?? false }

    func setVisible(_ visible: Bool) {
        if let surface { ghostty_surface_set_occlusion(surface, visible) }
    }

    // MARK: Automation

    /// Types `text` as keyboard input; each "\n" becomes a Return key press.
    func type(_ text: String) {
        guard let surface else { return }
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            if i > 0 {
                for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
                    var ev = ghostty_input_key_s()
                    ev.action = action
                    ev.keycode = 0x24 // kVK_Return
                    _ = ghostty_surface_key(surface, ev)
                }
            }
            if !line.isEmpty { _ = committedText(line) }
        }
    }

    // MARK: Layout and focus

    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface else { return }
        let px = convertToBacking(NSRect(origin: .zero, size: newSize)).size
        ghostty_surface_set_size(surface, UInt32(px.width), UInt32(px.height))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
        guard let surface else { return }
        // Not a backing/frame ratio: the first tab joins the window at zero size, and 0/0 gave it 1x text.
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        setFrameSize(frame.size)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface, let screen = window?.screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return }
        ghostty_surface_set_display_id(surface, id)
        viewDidChangeBackingProperties()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            syncFocus(isResponder: true)
            pane?.focusChanged(self)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { syncFocus(isResponder: false) }
        return ok
    }

    private var reportedFocus = true // libghostty starts surfaces focused

    /// libghostty blinks the cursor and runs vsync only for focused surfaces, so like
    /// Ghostty, a surface is focused only as first responder of the key window.
    func syncFocus(isResponder: Bool? = nil) {
        guard let surface else { return }
        let focused = window?.isKeyWindow == true && (isResponder ?? (window?.firstResponder === self))
        guard focused != reportedFocus else { return }
        reportedFocus = focused
        ghostty_surface_set_focus(surface, focused)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways, .cursorUpdate],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    // A cursor rect makes AppKit keep our cursor while the mouse moves; a bare set() gets reset.
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    func setCursor(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: cursor = .resizeUpDown
        default: cursor = .arrow
        }
        window?.invalidateCursorRects(for: self)
        cursor.set()
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT)
    }
    override func mouseUp(with event: NSEvent) {
        mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT)
        if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if !mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT) { super.rightMouseDown(with: event) }
    }
    override func rightMouseUp(with event: NSEvent) {
        if !mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT) { super.rightMouseUp(with: event) }
    }
    override func otherMouseDown(with event: NSEvent) {
        mouseButton(event, GHOSTTY_MOUSE_PRESS, event.buttonNumber == 2 ? GHOSTTY_MOUSE_MIDDLE : GHOSTTY_MOUSE_UNKNOWN)
    }
    override func otherMouseUp(with event: NSEvent) {
        mouseButton(event, GHOSTTY_MOUSE_RELEASE, event.buttonNumber == 2 ? GHOSTTY_MOUSE_MIDDLE : GHOSTTY_MOUSE_UNKNOWN)
    }

    @discardableResult
    private func mouseButton(_ event: NSEvent, _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, Self.mods(event.modifierFlags))
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        // -1/-1 tells libghostty the cursor left; skip while dragging so selection continues.
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        pane?.hoveredLink = nil // libghostty sends no "left the link" for off-surface positions
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX, y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        // Packed scroll mods: bit 0 = precision, bits 1-3 = momentum phase.
        let momentum: Int32 = switch event.momentumPhase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
        ghostty_surface_mouse_scroll(surface, x, y, (precise ? 1 : 0) | (momentum << 1))
    }

    override func pressureChange(with event: NSEvent) {
        if let surface { ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure)) }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else { return interpretKeyEvents([event]) }
        pane?.userTyped()

        // Apply option-as-alt and similar config by asking libghostty which mods translate text.
        let translated = Self.flags(ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        // Reuse the original event when nothing changed; Korean IMEs depend on its identity.
        let translationEvent = translationMods == event.modifierFlags ? event : NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.characters(byApplyingModifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedBefore = markedText.length > 0
        let layoutBefore = markedBefore ? nil : Self.keyboardLayoutID
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // An input-method switch shortcut changed the layout; don't send the key.
        if !markedBefore && layoutBefore != Self.keyboardLayoutID { return }

        syncPreedit(clearIfNeeded: markedBefore)
        let composing = markedText.length > 0 || markedBefore

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isComposingControl(text, composing) {
                if markedBefore {
                    _ = committedText(text)
                } else {
                    keyAction(action, event: event, translationEvent: translationEvent, text: text)
                }
            }
            if markedBefore, Self.replaysAfterCommit(translationEvent) {
                keyAction(action, event: event, translationEvent: translationEvent)
            }
            return
        }
        if Self.isComposingControl(event.characters, composing) { return }
        keyAction(action, event: event, translationEvent: translationEvent,
                  text: Self.ghosttyCharacters(translationEvent), composing: composing)
    }

    override func keyUp(with event: NSEvent) {
        keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, let surface else { return false }

        // Ghostty keybinds (cmd+t, cmd+d, cmd+c, ...) are handled by keyDown.
        var ev = Self.keyEvent(event, GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            ev.text = ptr
            return ghostty_surface_key_is_binding(surface, ev, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            // ctrl+/ beeps in AppKit; send it as ctrl+_ like other terminals.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            guard !event.modifierFlags.isDisjoint(with: [.command, .control]) else {
                lastPerformKeyEvent = nil
                return false
            }
            // Second pass of an unhandled cmd/ctrl key (see doCommand): encode it.
            if let last = lastPerformKeyEvent, last == event.timestamp {
                lastPerformKeyEvent = nil
                equivalent = event.characters ?? ""
            } else {
                lastPerformKeyEvent = event.timestamp
                return false
            }
        }
        guard let final = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        keyDown(with: final)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        var action = GHOSTTY_ACTION_RELEASE
        if Self.mods(event.modifierFlags).rawValue & mod != 0 {
            let raw = event.modifierFlags.rawValue
            let sidePressed = switch event.keyCode {
            case 0x3C: raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        keyAction(action, event: event)
    }

    @discardableResult
    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
                           text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var ev = Self.keyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        guard let text, !text.isEmpty, (text.unicodeScalars.first?.value ?? 0) >= 0x20 else {
            return ghostty_surface_key(surface, ev)
        }
        return text.withCString { ptr in
            ev.text = ptr
            return ghostty_surface_key(surface, ev)
        }
    }

    private func committedText(_ text: String) -> Bool {
        guard let surface else { return false }
        var ev = ghostty_input_key_s()
        ev.action = GHOSTTY_ACTION_PRESS
        return text.withCString { ptr in
            ev.text = ptr
            return ghostty_surface_key(surface, ev)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let s = markedText.string
            s.withCString { ghostty_surface_preedit(surface, $0, UInt(s.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    private static func keyEvent(_ event: NSEvent, _ action: ghostty_input_action_e,
                                 translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(event.keyCode)
        ev.mods = mods(event.modifierFlags)
        // Control and command never produce text; assume every other mod did.
        ev.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        if event.type == .keyDown || event.type == .keyUp,
           let c = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            ev.unshifted_codepoint = c.value
        }
        return ev
    }

    /// Text for a key event, leaving control characters and function-key PUA codes to libghostty's encoder.
    private static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return chars
    }

    private static func isComposingControl(_ text: String?, _ composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1 else { return false }
        return text.unicodeScalars.first!.value < 0x20
    }

    private static func replaysAfterCommit(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x7D, 0x7C, 0x7E: return true // down, right, up
        case 0x7B: return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command]) // left
        default: return false
        }
    }

    private static var keyboardLayoutID: String? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    private static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { f.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { f.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { f.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { f.insert(.command) }
        return f
    }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        // Outside keyDown (e.g. layout switch mid-composition) update preedit right away.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let rect = convert(NSRect(x: x, y: frame.height - y, width: range.length == 0 ? 0 : w, height: h), to: nil)
        return window?.convertToScreen(rect) ?? rect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars = switch string {
        case let v as NSAttributedString: v.string
        case let v as String: v
        default: ""
        }
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }
        // Dictation and other out-of-band input arrive here: send as typed text, never as paste.
        if !chars.isEmpty { _ = committedText(chars) }
    }

    override func doCommand(by selector: Selector) {
        // Re-dispatch an unhandled cmd/ctrl key so performKeyEquivalent's second pass encodes it.
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }
}
