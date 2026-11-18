import AppKit
import GhosttyKit

/// Prompts held for a pane's coding agent and sent one per finished turn. Helium collects them itself and
/// pastes each into the agent when its turn ends, so it works the same for every agent whose working and
/// blocked states Helium can see.
enum MessageQueue {
    struct State: Equatable {
        /// A coding agent is the pane's foreground program; a queue never types into a shell.
        var agent = false
        /// The agent the messages were queued for has exited and another one runs here now.
        var replaced = false
        var hung = false
        var editing = false
        /// The user typed here in the last few seconds; a paste now would land in the middle of their text.
        var typing = false
        var busy = false
        /// The agent shows a permission prompt or a question, where typed text would answer it.
        var blocked = false
        /// A turn was seen since the first message was queued or the last one was sent.
        var sawBusy = false
        /// The agent itself reports being idle, so the first message needn't wait for a turn.
        var knownIdle = false
        /// A message went out and no turn has been seen since: the idle report may predate it.
        var sent = false
    }

    /// Why the next message can't go out yet, as shown in the editor; nil means send it now.
    static func hold(_ s: State) -> String? {
        if !s.agent { return "No coding agent is running in this pane." }
        if s.replaced { return "The agent these were queued for has exited." }
        if s.hung { return "This pane isn't responding." }
        if s.editing { return "Paused while this is open." }
        if s.typing { return "Paused while you type in the pane." }
        if s.blocked { return "The agent is waiting for your answer." }
        if s.busy { return "Sends when the agent finishes." }
        if s.sawBusy { return nil }
        if s.sent { return "Waiting for the agent to start on the last message." }
        return s.knownIdle ? nil : "Sends after the agent's next turn."
    }
}

extension MainWindowController {
    func enqueue(_ text: String, for pane: PaneView) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if pane.queue.isEmpty {
            pane.queueSawBusy = false // an earlier turn doesn't count for this message
            pane.queueFor = pane.queueProcess
        }
        pane.queue.append(text)
    }

    /// Sends each pane's next message once its agent is done. Only `refreshMetadata` calls this, right after
    /// reading the agents' states: with older state, a message could land in a shell or a permission prompt.
    func drainQueues() {
        for pane in workspaces.flatMap(\.panes) {
            if pane.queueState.busy { pane.noteBusy() }
            if !pane.queue.isEmpty, MessageQueue.hold(pane.queueState) == nil { sendQueued(pane) }
        }
    }

    func sendQueued(_ pane: PaneView) {
        guard !pane.queue.isEmpty else { return }
        let text = pane.queue.removeFirst()
        pane.queueSawBusy = false
        pane.queueSent = true
        pane.surface.submit(text)
    }

    /// Edit > Queue Message for Agent: the focused pane's queue.
    @objc func queueMessage(_ sender: Any?) {
        if let pane = selected?.focusedPane { editQueue(pane) }
    }

    func editQueue(_ pane: PaneView) {
        guard pane.queuePopover == nil, let ws = pane.workspace else { return }
        if ws !== selected { select(ws) } // the popover needs the pane on screen
        let popover = NSPopover()
        popover.behavior = .transient
        let editor = QueueEditor(pane: pane, controller: self)
        popover.contentViewController = editor
        popover.delegate = editor
        window?.layoutIfNeeded()
        popover.show(relativeTo: NSRect(x: pane.bounds.maxX - 46, y: 6, width: 40, height: 16), of: pane, preferredEdge: .maxY)
        if popover.isShown { pane.queuePopover = popover }
    }
}

/// An editable text field as tall as its wrapped text (AppKit sizes only labels that way), up to about 8 lines.
private final class GrowingField: NSTextField {
    override var intrinsicContentSize: NSSize {
        guard let cell else { return super.intrinsicContentSize }
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: preferredMaxLayoutWidth, height: 140))
        return NSSize(width: NSView.noIntrinsicMetric, height: size.height)
    }

    override func textDidChange(_ notification: Notification) {
        invalidateIntrinsicContentSize()
        super.textDidChange(notification)
    }
}

/// The queue popover: each queued message in an editable field with a remove button, and a field to add more.
final class QueueEditor: NSViewController, NSTextFieldDelegate, NSPopoverDelegate {
    private let pane: PaneView
    private weak var controller: MainWindowController?
    private let list = NSStackView()
    private let draft = QueueEditor.field("")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let sendNow = NSButton(title: "Send Now", target: nil, action: #selector(sendFirst))
    private static let width: CGFloat = 340

    init(pane: PaneView, controller: MainWindowController?) {
        self.pane = pane
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func field(_ text: String, width: CGFloat = QueueEditor.width) -> NSTextField {
        let f = GrowingField(wrappingLabelWithString: text)
        f.isEditable = true
        f.isBezeled = true
        f.drawsBackground = true
        f.preferredMaxLayoutWidth = width
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        return f
    }

    /// Keeps the popover as tall as its fields while a message is typed.
    func controlTextDidChange(_ obj: Notification) {
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    override func loadView() {
        let title = NSTextField(labelWithString: pane.queueAgent.map { "Queue for \($0.displayName)" } ?? "Message queue")
        title.font = .boldSystemFont(ofSize: 12)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        draft.placeholderString = "Message to send when the agent finishes"
        draft.delegate = self
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = Self.width - 90
        sendNow.target = self
        sendNow.controlSize = .small
        sendNow.toolTip = "Send the first message without waiting for the agent"
        let footer = NSStackView(views: [status, NSView(), sendNow])

        let stack = NSStackView(views: [title, list, draft, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for v in [list, footer] { v.widthAnchor.constraint(equalToConstant: Self.width).isActive = true }
        view = stack
        reload()
    }

    /// Rebuilds the list from the pane's queue.
    private func reload() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, text) in pane.queue.enumerated() {
            let f = Self.field(text, width: Self.width - 26)
            f.delegate = self
            f.tag = i
            let x = NSButton(title: "✕", target: self, action: #selector(remove(_:)))
            x.isBordered = false
            x.tag = i
            x.setAccessibilityLabel("Cancel message \(i + 1)")
            let row = NSStackView(views: [f, x])
            row.alignment = .top
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        list.isHidden = pane.queue.isEmpty
        var state = pane.queueState
        state.editing = false
        let hold = MessageQueue.hold(state)
        draft.isEnabled = state.agent
        sendNow.isEnabled = state.agent && !pane.queue.isEmpty
        status.stringValue = !state.agent ? hold ?? ""
            : (hold ?? "Sends when you close this.") + " Return adds a message, Option-Return a new line."
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(draft)
    }

    @objc private func remove(_ sender: NSButton) {
        view.window?.makeFirstResponder(nil) // commit an edit in progress before the indexes shift
        if pane.queue.indices.contains(sender.tag) { pane.queue.remove(at: sender.tag) }
        reload()
        view.window?.makeFirstResponder(draft)
    }

    @objc private func sendFirst() {
        view.window?.makeFirstResponder(nil)
        controller?.sendQueued(pane)
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            view.window?.performClose(nil)
            return true
        }
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        if control === draft {
            let text = draft.stringValue
            draft.stringValue = ""
            controller?.enqueue(text, for: pane) // held while this popover is open
            reload()
        }
        view.window?.makeFirstResponder(draft) // from a queued message, this ends and saves the edit
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, f !== draft, pane.queue.indices.contains(f.tag),
              pane.queue[f.tag] != f.stringValue else { return }
        let emptied = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if emptied { pane.queue.remove(at: f.tag) } else { pane.queue[f.tag] = f.stringValue }
        // Not during this callback: reload removes the field that is ending its edit.
        if emptied { DispatchQueue.main.async { [weak self] in self?.reload() } }
    }

    func popoverWillClose(_ notification: Notification) {
        view.window?.makeFirstResponder(nil) // a click outside doesn't end a field's edit; save it
    }

    func popoverDidClose(_ notification: Notification) {
        pane.queuePopover = nil
        controller?.refreshMetadata()
        if let ws = pane.workspace, ws === controller?.selected { pane.window?.makeFirstResponder(pane.surface) }
    }
}
