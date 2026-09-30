import AppKit
import Carbon.HIToolbox

enum Paster {
    /// Stamped on Tinycast's own synthetic keystrokes so the snippet keyword tap can skip them.
    static let tinycastEventTag: Int64 = 0x54494E59

    /// Covers the gap between `activate()` returning and the target app accepting a keystroke.
    private static let activationDelay: TimeInterval = 0.08

    /// Shorter: no activation to wait on, only the pasteboard write reaching the target's process.
    private static let directPostDelay: TimeInterval = 0.05

    /// Write the item and paste it into `previousApp`, activating it so ⌘V lands there.
    @MainActor @discardableResult
    static func paste(
        _ item: ClipboardItem, store: ClipboardStore, previousApp: NSRunningApplication?,
        mode: ClipboardPasteMode = .original, representations: [ClipboardRepresentation] = []
    ) -> Bool {
        guard write(item, store: store, mode: mode, representations: representations) else { return false }
        store.promote(item)
        previousApp?.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(activationDelay))
            postCommandV()
        }
        return true
    }

    /// Put the item on the pasteboard without pasting; the marker stops re-capture.
    @MainActor @discardableResult
    static func copy(
        _ item: ClipboardItem, store: ClipboardStore, representations: [ClipboardRepresentation] = []
    ) -> Bool {
        guard write(item, store: store, representations: representations) else { return false }
        store.promote(item)
        return true
    }

    /// Put a string on the pasteboard unmarked, so it enters history like any other copy.
    @MainActor
    static func copyPlainText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
    }

    /// String counterpart of `paste`, marker-stamped so the text doesn't re-enter history.
    @MainActor
    static func pasteString(_ text: String, previousApp: NSRunningApplication?) {
        writeString(text)
        previousApp?.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(activationDelay))
            postCommandV()
        }
    }

    /// A file, pasted into `previousApp`; the receiver takes the file or its path, as it reads.
    @MainActor
    static func pasteFile(_ url: URL, previousApp: NSRunningApplication?) {
        PasteboardFiles.write(url, to: .general)
        previousApp?.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(activationDelay))
            postCommandV()
        }
    }

    /// String counterpart of `copy(_:store:)`.
    @MainActor
    static func copyString(_ text: String) {
        writeString(text)
    }

    /// String counterpart of `pasteInPlace`; the palette stays frontmost.
    @MainActor
    static func pasteStringInPlace(_ text: String, into app: NSRunningApplication?) {
        writeString(text)
        guard let pid = app?.processIdentifier else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(directPostDelay))
            postCommandV(toPid: pid)
        }
    }

    @MainActor
    private static func writeString(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, ClipboardManager.internalType], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: ClipboardManager.internalType)
    }

    /// Paste into `app` without activating or promoting, so the palette and its rows hold still.
    @MainActor @discardableResult
    static func pasteInPlace(
        _ item: ClipboardItem, store: ClipboardStore, into app: NSRunningApplication?,
        mode: ClipboardPasteMode = .original, representations: [ClipboardRepresentation] = [],
        addNewline: Bool = false
    ) -> Bool {
        guard write(item, store: store, mode: mode, representations: representations) else { return false }
        if let pid = app?.processIdentifier {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(directPostDelay))
                postCommandV(toPid: pid)
                if ClipboardPasteMode.appendsNewline(to: item, enabled: addNewline) {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        postNewline(toPid: pid)
                    }
                }
            }
        }
        return true
    }

    /// Whether anything was written; a vanished item leaves the pasteboard untouched.
    @MainActor @discardableResult
    static func write(
        _ item: ClipboardItem, store: ClipboardStore, to pb: NSPasteboard = .general,
        mode: ClipboardPasteMode = .original, representations: [ClipboardRepresentation] = []
    ) -> Bool {
        if mode == .plainText, let text = item.plainText {
            let payload = NSPasteboardItem()
            payload.setString(text, forType: .string)
            payload.setData(Data(), forType: ClipboardManager.internalType)
            pb.clearContents()
            return pb.writeObjects([payload])
        }
        let representations = ClipboardRepresentation.bounded(representations)
        let available = representations.map(\.type)
        let selected = representations.filter { mode.selects($0.type, available: available) }
        if !selected.isEmpty {
            let payload = NSPasteboardItem()
            for representation in selected {
                payload.setData(representation.data, forType: .init(representation.type))
            }
            payload.setData(Data(), forType: ClipboardManager.internalType)
            pb.clearContents()
            return pb.writeObjects([payload])
        }
        guard mode == .original || mode == .plainText else { return false }
        let payload = NSPasteboardItem()
        switch item.kind {
        case .text:
            guard let text = item.text else { return false }
            payload.setString(text, forType: .string)
        case .image:
            guard let url = store.imageURL(for: item),
                let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            else { return false }
            payload.setData(data, forType: .png)
        case .file:
            guard let url = store.fileURL(for: item),
                FileManager.default.fileExists(atPath: url.path)
            else { return false }
            payload.setData(url.dataRepresentation, forType: .fileURL)
            payload.setString(url.path, forType: .string)
        }
        payload.setData(Data(), forType: ClipboardManager.internalType)
        pb.clearContents()
        return pb.writeObjects([payload])
    }

    @MainActor
    private static func postNewline(toPid pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            guard
                let event = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: CGKeyCode(kVK_Return), keyDown: isDown)
            else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: tinycastEventTag)
            event.postToPid(pid)
        }
    }

    /// Synthesize ⌘V, to `pid` alone when given, else through the system tap.
    @MainActor
    static func postCommandV(toPid pid: pid_t? = nil) {
        postCommand(key: CGKeyCode(kVK_ANSI_V), toPid: pid)
    }

    /// Synthesize ⌘C, for reading a selection an app will not surface over Accessibility.
    @MainActor
    static func postCommandC(toPid pid: pid_t? = nil) {
        postCommand(key: CGKeyCode(kVK_ANSI_C), toPid: pid)
    }

    @MainActor
    private static func postCommand(key: CGKeyCode, toPid pid: pid_t?) {
        guard Permissions.ensureAccessibility() else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: tinycastEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: tinycastEventTag)

        if let pid {
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
