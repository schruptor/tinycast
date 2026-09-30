import AppKit

/// Owns clipboard-history actions: paste, copy, reveal, pin — and the selection that follows.
@MainActor
final class ClipboardCoordinator {
    private let clipboardStore: ClipboardStore
    private let clipboardManager: ClipboardManager
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let palette: PaletteState
    private let windowController: PaletteWindowController
    private let paletteCoordinator: PaletteCoordinator
    /// Dialogs, for the one action here that can't be undone.
    private unowned let core: AppCore
    /// One Copy Text at a time: a newer trigger cancels the helper an older one is waiting on.
    private var textTask: Task<Void, Never>?
    private var pasteSequence: PasteSequence?
    private var pasteTask: Task<Void, Never>?

    init(
        clipboardStore: ClipboardStore,
        clipboardManager: ClipboardManager,
        settings: AppSettings,
        appIndex: AppIndex,
        palette: PaletteState,
        windowController: PaletteWindowController,
        paletteCoordinator: PaletteCoordinator,
        core: AppCore
    ) {
        self.clipboardStore = clipboardStore
        self.clipboardManager = clipboardManager
        self.settings = settings
        self.appIndex = appIndex
        self.palette = palette
        self.windowController = windowController
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    /// Off means the poller stops, the database closes and nothing new is ever recorded.
    func applyEnabled() {
        appIndex.setCommandsVisible(
            [.clipboardHistory, .pasteSequentially, .resetPasteSequence], settings.clipboardEnabled)
        guard settings.clipboardEnabled else {
            pasteTask?.cancel()
            pasteSequence = nil
            core.applyClipboardTextSearch()
            clipboardManager.stop()
            if palette.mode == .clipboard { palette.prepare(mode: .launcher) }
            clipboardStore.close()
            return
        }
        clipboardStore.open()
        clipboardStore.maxAge = settings.clipboardRetention.maxAge
        clipboardManager.start()
        core.applyClipboardTextSearch()
        // Deferred off the launch path: the palette fills in behind the SQLite read and prune.
        Task { clipboardStore.load() }
    }

    func followSearchResults(query: String, previous: [ClipboardItem], current: [ClipboardItem]) {
        guard palette.isVisible, palette.mode == .clipboard,
            palette.query.trimmingCharacters(in: .whitespaces) == query,
            previous.indices.contains(palette.selection)
        else { return }
        let selectedID = previous[palette.selection].id
        if let index = current.firstIndex(where: { $0.id == selectedID }) {
            palette.selection = index
        }
    }

    /// The setting names an age, the store enforces it; a shortened window culls straight away.
    func applyRetention(_ retention: ClipboardRetention) {
        clipboardStore.maxAge = retention.maxAge
        clipboardStore.enforceLimits()
    }

    /// ↵ runs the configured default and the other chords follow it; false when `chord` has none.
    @discardableResult
    func activate(_ item: ClipboardItem, chord: ClipboardChord = .return) -> Bool {
        guard let action = settings.clipboardDefaultAction.action(for: chord, on: item) else {
            return false
        }
        perform(action, on: item)
        return true
    }

    func perform(_ action: ClipboardDefaultAction, on item: ClipboardItem) {
        switch action {
        case .paste: paste(item)
        case .copy: copyToClipboard(item)
        case .pastePlainText: pasteAsPlainText(item)
        }
    }

    isolated deinit { pasteTask?.cancel() }

    private func defaultMode(for item: ClipboardItem) -> ClipboardPasteMode {
        ClipboardPasteMode.preferred(for: item, plainText: settings.clipboardPreferPlainText)
    }

    func paste(_ item: ClipboardItem) { paste(item, mode: defaultMode(for: item)) }

    func paste(_ item: ClipboardItem, mode: ClipboardPasteMode) {
        restore(item, mode: mode, copying: false, keepingOpen: false)
    }

    func pasteAsPlainText(_ item: ClipboardItem) { paste(item, mode: .plainText) }

    func pasteKeepingWindowOpen(_ item: ClipboardItem) {
        restore(item, mode: defaultMode(for: item), copying: false, keepingOpen: true)
    }

    private func restore(
        _ item: ClipboardItem, mode: ClipboardPasteMode, copying: Bool, keepingOpen: Bool
    ) {
        guard pasteTask == nil else { return }
        clipboardManager.prepareForTinycastPasteboardMutation()
        let previous = windowController.previousApp
        pasteTask = Task { [weak self] in
            guard let self else { return }
            defer { pasteTask = nil }
            guard let (current, representations) = await payload(for: item.id) else { return }
            if !keepingOpen { paletteCoordinator.hidePalette(restoreFocus: false) }
            let succeeded: Bool
            if copying {
                succeeded = Paster.copy(current, store: clipboardStore, representations: representations)
            } else if keepingOpen {
                succeeded = Paster.pasteInPlace(
                    current, store: clipboardStore, into: previous,
                    mode: mode, representations: representations)
            } else {
                succeeded = Paster.paste(
                    current, store: clipboardStore, previousApp: previous,
                    mode: mode, representations: representations)
            }
            if succeeded { selectClip(current) } else { reportUnavailable(current) }
        }
    }

    private func payload(for id: UUID) async -> (ClipboardItem, [ClipboardRepresentation])? {
        await clipboardManager.flushCapture()
        while !Task.isCancelled {
            await clipboardStore.flushRepresentations()
            guard let item = clipboardStore.item(withID: id) else { return nil }
            if item.representationTypes.isEmpty { return (item, []) }
            let url = clipboardStore.dbURL
            let representations = await Task.detached(priority: .userInitiated) {
                ClipboardRepresentationStore.read(for: id, inDatabaseAt: url)
            }.value
            if !Task.isCancelled, clipboardStore.item(withID: id) == item { return (item, representations) }
        }
        return nil
    }

    func resetPasteSequence() {
        pasteTask?.cancel()
        pasteSequence = nil
        if paletteCoordinator.isVisible { paletteCoordinator.hidePalette() }
        core.showMessage("Paste sequence reset")
    }

    func pasteNextInSequence() {
        guard settings.clipboardEnabled, pasteTask == nil else { return }
        let now = Date()
        if let pasteSequence, pasteSequence.isSettling(at: now) { return }
        guard let target = paletteCoordinator.targetApp else { return }
        clipboardManager.prepareForTinycastPasteboardMutation()
        pasteTask = Task { [weak self] in
            guard let self else { return }
            defer { pasteTask = nil }
            await clipboardManager.flushCapture()
            var sequence = continuingPasteSequence(at: now)
            while let next = sequence.next(resolve: { clipboardStore.item(withID: $0) }) {
                guard let (item, representations) = await payload(for: next.id) else {
                    if Task.isCancelled { return }
                    continue
                }
                if paletteCoordinator.isVisible { paletteCoordinator.hidePalette() }
                guard
                    Paster.pasteInPlace(
                        item, store: clipboardStore, into: target,
                        mode: defaultMode(for: item), representations: representations,
                        addNewline: settings.clipboardSequenceNewline)
                else {
                    reportUnavailable(item)
                    continue
                }
                sequence.recordPaste(changeCount: NSPasteboard.general.changeCount, at: Date())
                pasteSequence = sequence
                return
            }
            pasteSequence = sequence
            core.showMessage("Nothing left to paste", tone: .neutral)
        }
    }

    private func continuingPasteSequence(at now: Date) -> PasteSequence {
        let changeCount = NSPasteboard.general.changeCount
        if let pasteSequence,
            pasteSequence.continues(
                changeCount: changeCount, at: now,
                timeout: TimeInterval(settings.clipboardSequenceTimeout.rawValue),
                captureIdentity: clipboardStore.captureIdentity)
        {
            return pasteSequence
        }
        return PasteSequence(
            entryIDs: clipboardStore.sequenceIDs(), changeCount: changeCount,
            now: now, captureIdentity: clipboardStore.captureIdentity)
    }

    func editContent(_ item: ClipboardItem) {
        guard item.kind == .text else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let text = await core.editClipboardText(item.text ?? "", renaming: false) else { return }
            if !clipboardStore.editContent(item, to: text) {
                core.showMessage("Couldn’t save clipboard content", tone: .danger)
            }
        }
    }

    func renameEntry(_ item: ClipboardItem) {
        Task { [weak self] in
            guard let self else { return }
            guard let name = await core.editClipboardText(item.customName ?? "", renaming: true) else {
                return
            }
            if !clipboardStore.rename(item, to: name) {
                core.showMessage("Couldn’t save clipboard name", tone: .danger)
            }
        }
    }

    /// A write only fails on a vanished file, and a palette that just closes explains nothing.
    private func reportUnavailable(_ item: ClipboardItem) {
        let message =
            switch item.kind {
            case .file: "That file has moved or been deleted."
            case .image: "That image is no longer available."
            case .text: "That format is no longer available."
            }
        core.showMessage(message, tone: .danger)
    }

    /// Both the ⌃⇧X chord and the menu row land here, so neither can skip the confirmation.
    func deleteAllClips() async {
        guard
            await core.confirm(
                title: "Delete All Entries",
                message: "Are you sure you want to proceed with deleting all clipboard history entries?",
                symbol: PaletteMode.clipboard.systemImage, confirmTitle: "Delete All")
        else { return }
        clearHistory()
    }

    /// Reachable with the feature off, so what was kept before can still be erased afterwards.
    func clearHistory() {
        clipboardStore.open()
        clipboardStore.clearAll()
        if !settings.clipboardEnabled { clipboardStore.close() }
    }

    func copyToClipboard(_ item: ClipboardItem) {
        restore(item, mode: .original, copying: true, keepingOpen: false)
    }

    /// Unmarked, so a converted colour enters history itself — it is one you meant to keep.
    func copyColor(_ color: ColorValue, as format: ColorFormat) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(format.string(for: color))
    }

    func revealClip(_ item: ClipboardItem) {
        guard let url = clipURL(for: item) else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        AppLauncher.showInFinder(url)
    }

    /// Nil only for a vanished file, which the HUD reports rather than hand over a dead path.
    func dragPayload(for item: ClipboardItem) -> ClipDragPayload? {
        let payload = item.dragPayload
        guard case .file = payload else { return payload }
        return clipURL(for: item).map(ClipDragPayload.file)
    }

    func openClip(_ item: ClipboardItem) {
        guard let url = clipURL(for: item) else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        AppLauncher.open(url)
    }

    /// Unmarked, so the path enters history like any other copy the reader meant to make.
    func copyClipPath(_ item: ClipboardItem) {
        guard let path = item.filePath else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(path)
        core.showMessage("Copied path")
    }

    /// ⇧⌘T / “Copy Text” — OCRs the image in the bundled helper and copies what it reads.
    func copyImageText(_ item: ClipboardItem) {
        guard let path = item.imagePath ?? item.filePath else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        core.showProgress("Reading text…")
        let changeCount = NSPasteboard.general.changeCount
        textTask?.cancel()
        textTask = Task {
            do {
                // A stat on an unmounted or network volume can stall, so it stays off the main actor.
                let exists = await Task.detached { FileManager.default.fileExists(atPath: path) }.value
                try Task.checkCancellation()
                guard exists else {
                    return item.kind == .file
                        ? reportUnavailable(item)
                        : core.showMessage("That image is no longer available.", tone: .danger)
                }
                let text = try await ClipboardTextWorker.extract(item)
                guard !text.isEmpty else { return core.showMessage("No text found", tone: .neutral) }
                guard NSPasteboard.general.changeCount == changeCount else {
                    return core.showMessage("Clipboard changed, text not copied", tone: .neutral)
                }
                Paster.copyPlainText(text)
                core.showMessage("Copied text")
            } catch is CancellationError {
            } catch {
                core.showMessage("Couldn’t read the text", tone: .danger)
            }
        }
    }

    /// Nil once the file is gone, so every action reports rather than silently no-opping.
    private func clipURL(for item: ClipboardItem) -> URL? {
        let url = clipboardStore.imageURL(for: item) ?? clipboardStore.fileURL(for: item)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            reportUnavailable(item)
            return nil
        }
        return url
    }

    /// Pin or unpin an entry; the selection and scroll follow the row as it moves.
    func togglePinnedClip(_ item: ClipboardItem) {
        clipboardStore.togglePinned(item)
        selectClip(item)
        palette.followToken = UUID()
    }

    /// Select `item`'s row as currently filtered; a moved row isn't always index 0.
    private func selectClip(_ item: ClipboardItem) {
        palette.selection =
            clipboardStore.rowIndex(
                of: item, in: palette.query, filter: palette.clipboardFilter) ?? 0
    }
}
