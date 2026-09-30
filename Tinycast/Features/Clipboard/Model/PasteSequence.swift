import Foundation

/// Paste Sequentially's walk down history, newest first, frozen when the walk begins.
struct PasteSequence: Sendable {
    static let idleTimeout: TimeInterval = 30
    /// Outlasts ⌘V's post delay and the target's read, so the next write cannot beat that read.
    static let settleInterval: TimeInterval = 0.25

    /// Ids rather than items, so an entry deleted mid-walk is skipped instead of pasted.
    private let entryIDs: [ClipboardItem.ID]
    private let captureIdentity: UUID?
    let startIdentity: ClipboardItem.ID?
    private var nextIndex = 0
    /// The pasteboard as our last write left it; any other count is a copy made since.
    private var changeCount: Int
    private var lastPaste: Date

    init(history: [ClipboardItem], changeCount: Int, now: Date) {
        self.init(entryIDs: history.map(\.id), changeCount: changeCount, now: now)
    }

    init(entryIDs: [UUID], changeCount: Int, now: Date, captureIdentity: UUID? = nil) {
        self.entryIDs = entryIDs
        self.captureIdentity = captureIdentity
        startIdentity = entryIDs.first
        self.changeCount = changeCount
        lastPaste = now
    }

    func continues(
        changeCount: Int, at now: Date, timeout: TimeInterval = Self.idleTimeout,
        captureIdentity: UUID? = nil
    ) -> Bool {
        let unchanged =
            captureIdentity.map { $0 == self.captureIdentity } ?? (changeCount == self.changeCount)
        return unchanged && now.timeIntervalSince(lastPaste) < timeout
    }

    func isSettling(at now: Date) -> Bool {
        now.timeIntervalSince(lastPaste) < Self.settleInterval
    }

    /// Nil at the end, where the walk stops rather than wrap back to the newest entry.
    mutating func next(in history: [ClipboardItem]) -> ClipboardItem? {
        next { id in history.first { $0.id == id } }
    }

    mutating func next(resolve: (UUID) -> ClipboardItem?) -> ClipboardItem? {
        while nextIndex < entryIDs.endIndex {
            let id = entryIDs[nextIndex]
            nextIndex += 1
            if let item = resolve(id) { return item }
        }
        return nil
    }

    /// Our own write moves the count, so the walk adopts it rather than read it as a new copy.
    mutating func recordPaste(changeCount: Int, at now: Date) {
        self.changeCount = changeCount
        lastPaste = now
    }
}
