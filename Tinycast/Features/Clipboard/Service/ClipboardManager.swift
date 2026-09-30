import AppKit

@MainActor
final class ClipboardManager {
    /// Marker we attach to the pasteboard when *we* write to it, so polling ignores our own pastes.
    nonisolated static let internalType = NSPasteboard.PasteboardType("com.tinycast.internal")

    /// Longest text captured; bigger copies are skipped, truncation losing the tail.
    static let maxTextLength = 32_000

    /// Markers put on secret copies by password managers, browsers and the OS.
    nonisolated static let sensitiveTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("com.apple.is-sensitive")
    ]

    private let store: ClipboardStore
    private let settings: AppSettings
    private var timer: Timer?
    private var imageTask: Task<Void, Never>?
    private var representationTask: Task<Void, Never>?
    private var pendingRepresentationRequests = 0
    private var sessionTokens: [NotificationToken] = []
    private var lastChangeCount = 0
    private var isCapturing = false

    init(store: ClipboardStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    // Isolated so teardown can touch the main-actor timer; the poll block is already weak.
    isolated deinit {
        timer?.invalidate()
        imageTask?.cancel()
        representationTask?.cancel()
    }

    func start() {
        guard !isCapturing else { return }
        isCapturing = true
        installSessionObservers()
        startPolling()
    }

    /// Turning the feature off: the poller, the observers and the drain all go with it.
    func stop() {
        imageTask?.cancel()
        representationTask?.cancel()
        isCapturing = false
        sessionTokens = []
        stopPolling()
    }

    // Fast user switching: another session's clipboard isn't ours, so stop waking up for it.
    private func installSessionObservers() {
        guard sessionTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sessionTokens = [
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.sessionDidResignActiveNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stopPolling() }
                }, center: center),
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.startPolling() }
                }, center: center)
        ]
    }

    // Re-baselining first is what stops a clip made in another session reading as new on resume.
    private func startPolling() {
        guard isCapturing, timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // Drain first: the real copy must reach history before we overwrite the pasteboard.
    func prepareForTinycastPasteboardMutation() {
        guard isCapturing else { return }
        poll()
    }

    func flushCapture() async {
        await imageTask?.value
        await representationTask?.value
    }

    // Load-bearing: a mismatched count means a foreign write the next poll must still see.
    func synchronizeAfterTinycastPasteboardMutation(changeCount: Int) {
        guard NSPasteboard.general.changeCount == changeCount else { return }
        lastChangeCount = changeCount
    }

    /// A Finder select-all must not insert ten thousand rows on one poll tick.
    nonisolated static let maxCapturedFiles = 32

    /// Reclaimable roots, without the `/private` that `resolvingSymlinksInPath` strips.
    nonisolated static let volatileRoots = [
        "/tmp/", "/var/tmp/", "/var/folders/", NSHomeDirectory() + "/Library/Caches/"
    ]

    /// Both parameters are injected environment facts, so a harness can drive its own scratch.
    nonisolated static func fileURLs(
        on pasteboard: NSPasteboard, volatileRoots roots: [String] = volatileRoots
    ) -> [String]? {
        let durable = PasteboardFiles.urls(on: pasteboard, limit: maxCapturedFiles) {
            isDurable($0, roots: roots)
        }
        // Nil rather than empty, so a copied `http` URL falls through and stays a link.
        guard !durable.isEmpty else { return nil }
        // Reversed on insert, so the first file copied ends up leading the history.
        return durable.map(\.standardizedFileURL.path).reversed()
    }

    /// An app that stages a temp file beside better inline content must keep the inline content.
    nonisolated private static func isDurable(_ url: URL, roots: [String]) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var path = url.resolvingSymlinksInPath().path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        return !roots.contains { path.hasPrefix($0) }
    }

    nonisolated static func representations(
        on pasteboard: NSPasteboard, matchingText: String? = nil
    ) -> [ClipboardRepresentation] {
        let types = (pasteboard.types ?? []) + (pasteboard.pasteboardItems ?? []).flatMap(\.types)
        guard !types.contains(internalType), Set(types).isDisjoint(with: sensitiveTypes) else { return [] }
        let item = pasteboard.pasteboardItems?.first {
            matchingText == nil || ($0.string(forType: .string) ?? $0.string(forType: .URL)) == matchingText
        }
        guard let item else { return [] }
        var representations: [ClipboardRepresentation] = []
        var bytes = 0
        for type in item.types where ClipboardRepresentation.allowedTypes.contains(type.rawValue) {
            guard let data = item.data(forType: type), !data.isEmpty,
                data.count <= ClipboardRepresentation.maximumBytes,
                bytes + data.count <= ClipboardRepresentation.maximumEntryBytes
            else { continue }
            representations.append(ClipboardRepresentation(type: type.rawValue, data: data))
            bytes += data.count
        }
        return representations
    }

    nonisolated private static func readRepresentations(
        name: String, changeCount: Int, matchingText: String?
    ) -> [ClipboardRepresentation] {
        let pasteboard = NSPasteboard(name: .init(name))
        guard pasteboard.changeCount == changeCount else { return [] }
        let result = representations(on: pasteboard, matchingText: matchingText)
        return pasteboard.changeCount == changeCount ? result : []
    }

    private func captureRepresentations(
        for item: ClipboardItem, on pasteboard: NSPasteboard, matchingText: String? = nil
    ) {
        guard pendingRepresentationRequests < 8 else { return }
        pendingRepresentationRequests += 1
        let previous = representationTask
        let name = pasteboard.name.rawValue
        let changeCount = pasteboard.changeCount
        representationTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { pendingRepresentationRequests -= 1 }
            guard !Task.isCancelled, isCapturing else { return }
            let result = await Task.detached(priority: .utility) {
                Self.readRepresentations(name: name, changeCount: changeCount, matchingText: matchingText)
            }.value
            guard !Task.isCancelled, isCapturing, !result.isEmpty else { return }
            store.captureRepresentations(result, for: item)
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        let changeCount = pb.changeCount
        lastChangeCount = changeCount

        // Never record secrets: skip copies tagged sensitive by any of the marker owners.
        let types = (pb.types ?? []) + (pb.pasteboardItems ?? []).flatMap(\.types)
        if types.contains(Self.internalType) || !Set(types).isDisjoint(with: Self.sensitiveTypes) { return }

        // The pasteboard carries no source, so attribute it to the frontmost app.
        let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let sourceBundleID, settings.clipboardDisabledApps.contains(sourceBundleID) { return }

        // Ahead of the text branch: Finder puts the file's *name* on `.string` beside its URL.
        if let paths = Self.fileURLs(on: pb) {
            guard pb.changeCount == changeCount else { return }
            store.addFiles(paths, sourceBundleID: sourceBundleID)
            return
        }

        if let text = pb.string(forType: .string) ?? pb.string(forType: .URL),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            guard text.count <= Self.maxTextLength else { return }
            guard pb.changeCount == changeCount else { return }
            let item = store.addText(text, sourceBundleID: sourceBundleID)
            captureRepresentations(for: item, on: pb, matchingText: text)
            return
        }

        if let color = NSColor(from: pb)?.usingColorSpace(.deviceRGB) {
            let text = String(
                format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
            guard pb.changeCount == changeCount else { return }
            let item = store.addText(text, sourceBundleID: sourceBundleID)
            captureRepresentations(for: item, on: pb)
            return
        }

        if let type = pb.availableType(from: [.png, .tiff]), let data = pb.data(forType: type) {
            guard pb.changeCount == changeCount else { return }
            let name = pb.name.rawValue
            let isPNG = type == .png
            let store = store
            // A big TIFF→PNG re-encode can take 100ms+, so keep the poll off that path.
            let previous = imageTask
            imageTask = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled, self?.isCapturing == true else { return }
                let result = await Task.detached(priority: .utility) {
                    let representations = Self.readRepresentations(
                        name: name, changeCount: changeCount, matchingText: nil)
                    let png =
                        isPNG
                        ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
                    return (png, representations)
                }.value
                guard !Task.isCancelled, self?.isCapturing == true, let png = result.0 else { return }
                await store.addImage(png, sourceBundleID: sourceBundleID, representations: result.1)
            }
        }
    }
}
