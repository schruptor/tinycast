import AppKit
import Contacts
import Foundation
import Observation

@MainActor
@Observable
final class ContactsStore {
    private(set) var entries: [AppEntry] = []
    private(set) var access: ContactsAccess = .notDetermined
    private(set) var isLoading = false
    private(set) var failed = false
    private(set) var revision = 0
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var reader: ContactReader?
    @ObservationIgnored private var observer: NotificationToken?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<[AppEntry], Error>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var thumbnails: NSCache<NSString, NSImage>?
    @ObservationIgnored private var thumbnailTasks: [String: Task<Data?, Never>] = [:]
    @ObservationIgnored private let readAccess: @Sendable () -> ContactsAccess
    @ObservationIgnored private let load: (@Sendable (ContactsOptions) throws -> [AppEntry])?
    @ObservationIgnored private let askAccess: @Sendable () async -> Void
    private var options = ContactsOptions()

    init(
        readAccess: @escaping @Sendable () -> ContactsAccess = ContactReader.access,
        load: (@Sendable (ContactsOptions) throws -> [AppEntry])? = nil,
        askAccess: @escaping @Sendable () async -> Void = ContactReader.requestAccess
    ) {
        self.readAccess = readAccess
        self.load = load
        self.askAccess = askAccess
    }

    func launcherEntries(showsInLauncher: Bool) -> [AppEntry] {
        running && access == .authorized && showsInLauncher ? entries : []
    }

    func refreshAccess() { access = readAccess() }

    func requestAccess() async {
        refreshAccess()
        guard access == .notDetermined else { return }
        await askAccess()
        refreshAccess()
    }

    func start(options: ContactsOptions) {
        let needsRefresh = !running || self.options != options || observer == nil || failed
        self.options = options
        running = true
        refreshAccess()
        guard access == .authorized else {
            stop()
            running = true
            return
        }
        if reader == nil, load == nil { reader = ContactReader() }
        if observer == nil {
            let center = NotificationCenter.default
            let token = center.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            observer = NotificationToken(token, center: center)
        }
        if needsRefresh { refresh() }
    }

    func stop() {
        running = false
        generation &+= 1
        pending = false
        observer = nil
        reader = nil
        debounce?.cancel()
        debounce = nil
        refreshTask?.cancel()
        worker?.cancel()
        releaseThumbnails()
        failed = false
        isLoading = false
        publish([])
    }

    private func scheduleRefresh() {
        guard running else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.refresh()
        }
    }

    func refresh() {
        guard running else { return }
        guard refreshTask == nil else { pending = true; return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.pending = false
                let generation = self.generation
                self.refreshAccess()
                guard self.running, self.access == .authorized else {
                    self.observer = nil
                    self.reader = nil
                    self.publish([])
                    break
                }
                self.isLoading = true
                let options = self.options
                guard let load = self.load ?? self.reader?.load else { break }
                let work = Task.detached(priority: .utility) { try load(options) }
                self.worker = work
                do {
                    let entries = try await work.value
                    if self.running, generation == self.generation {
                        self.failed = false
                        self.publish(entries)
                    }
                } catch {
                    if self.running, generation == self.generation {
                        self.refreshAccess()
                        self.failed = self.access == .authorized
                        self.publish([])
                    }
                }
                self.worker = nil
            } while self.running && self.pending
            self.isLoading = false
            self.refreshTask = nil
        }
    }

    func thumbnail(id: String) async -> NSImage? {
        guard running, access == .authorized else { return nil }
        if let image = thumbnails?.object(forKey: id as NSString) { return image }
        let stamp = generation
        let revision = revision
        guard let reader else { return nil }
        let work = thumbnailTasks[id] ?? Task.detached(priority: .utility) { reader.thumbnail(id: id) }
        thumbnailTasks[id] = work
        let data = await work.value
        guard running, access == .authorized, stamp == generation, revision == self.revision else { return nil }
        thumbnailTasks[id] = nil
        guard !Task.isCancelled, let data, let image = NSImage(data: data) else { return nil }
        if thumbnails == nil {
            thumbnails = NSCache()
            thumbnails?.countLimit = 64
            thumbnails?.totalCostLimit = 2 * 1024 * 1024
        }
        let cost = data.count + Int(image.size.width * image.size.height * 4)
        thumbnails?.setObject(image, forKey: id as NSString, cost: cost)
        return image
    }

    func releaseThumbnails() {
        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks.removeAll()
        thumbnails = nil
    }

    private func publish(_ next: [AppEntry]) {
        releaseThumbnails()
        entries = next
        revision &+= 1
        onChange?()
    }
}
