import AppKit

@MainActor
@Observable
final class ContactsCoordinator {
    let store: ContactsStore
    private let index: AppIndex
    private let settings: AppSettings
    private let ranking: LauncherRankingStore
    private let palette: PaletteCoordinator
    private unowned let core: AppCore
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var memo = Memo<Key, [AppEntry]>()

    private struct Key: Equatable {
        let query: String
        let revision: Int
        let ranking: Int
        let sensitivity: SearchSensitivity
    }

    init(
        store: ContactsStore, index: AppIndex, settings: AppSettings,
        ranking: LauncherRankingStore, palette: PaletteCoordinator, core: AppCore) {
        self.store = store
        self.index = index
        self.settings = settings
        self.ranking = ranking
        self.palette = palette
        self.core = core
    }

    private var options: ContactsOptions {
        ContactsOptions(phones: settings.contactsSearchPhones, emails: settings.contactsSearchEmails,
            organizations: settings.contactsSearchOrganizations)
    }

    func setEnabled(_ enabled: Bool) {
        settings.contactsEnabled = enabled
        applyEnabled()
        if enabled { grantAccess() }
    }

    func grantAccess() {
        guard settings.contactsEnabled, permissionTask == nil else { return }
        permissionTask = Task { [weak self] in
            guard let self else { return }
            await store.requestAccess()
            if settings.contactsEnabled { store.start(options: options) }
            permissionTask = nil
        }
    }

    func applyEnabled() {
        index.setCommandsVisible([.searchContacts], settings.contactsEnabled)
        memo = Memo()
        guard settings.contactsEnabled else {
            store.stop()
            publishEntries()
            if core.palette.mode == .contacts { palette.hidePalette(restoreFocus: true) }
            return
        }
        store.onChange = { [weak self] in
            self?.memo = Memo()
            self?.publishEntries()
        }
        store.start(options: options)
    }

    func applyPhotos() {
        if !settings.contactsShowPhotos { store.releaseThumbnails() }
    }

    func reloadOptions() {
        guard settings.contactsEnabled else { return }
        store.start(options: options)
    }

    func publishEntries() {
        let visible = settings.contactsEnabled && settings.contactsShowInLauncher
        index.setContacts(store.launcherEntries(showsInLauncher: visible))
    }

    func prepare() {
        guard settings.contactsEnabled else { return }
        store.refreshAccess()
        if store.access != .authorized || store.entries.isEmpty { store.start(options: options) }
    }

    func show() {
        guard settings.contactsEnabled else { return }
        prepare()
        palette.togglePalette(mode: .contacts)
        if store.access == .notDetermined { grantAccess() }
    }

    func results(query: String) -> [AppEntry] {
        guard settings.contactsEnabled, store.access == .authorized else { return [] }
        let key = Key(query: query, revision: store.revision, ranking: ranking.revision,
            sensitivity: settings.rootSearchSensitivity)
        return memo.value(for: key) { index.ordered(store.entries, query: query) }
    }

    func open(_ entry: AppEntry, recordVisit: Bool = true) {
        run(.contacts, entry: entry, recordVisit: recordVisit)
    }

    func perform(_ shortcut: PaletteShortcut, entry: AppEntry) -> Bool {
        guard let contact = entry.contact else { return false }
        switch shortcut {
        case .copyFile: run(.copy(contact.primaryValue), entry: entry)
        case .copyName: run(.copy(contact.displayName), entry: entry)
        default: return false
        }
        return true
    }

    func actions(for entry: AppEntry) -> PopoverMenuContent? {
        guard settings.contactsEnabled, let contact = entry.contact else { return nil }
        let items = ContactAction.actions(for: contact).compactMap { action -> PopoverMenuItem? in
            if case .url(let url) = action.destination,
                NSWorkspace.shared.urlForApplication(toOpen: url) == nil { return nil }
            return PopoverMenuItem(title: action.title, systemImage: action.symbol,
                shortcut: action.shortcut) { [weak self] in self?.run(action.destination, entry: entry) }
        }
        return PopoverMenuContent(header: contact.displayName, items: items)
    }

    private func run(_ destination: ContactAction.Destination, entry: AppEntry, recordVisit: Bool = true) {
        prepare()
        guard settings.contactsEnabled, store.access == .authorized,
            store.entries.contains(where: { $0.id == entry.id }) else { return }
        if recordVisit { ranking.visit(itemKey: entry.preferenceKey, query: nil) }
        palette.hidePalette(restoreFocus: false)
        switch destination {
        case .copy(let value):
            Paster.copyString(value)
            core.showMessage("Contact value copied")
        case .contacts:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.AddressBook") else {
                core.showMessage("Contacts is unavailable", tone: .neutral)
                return
            }
            AppLauncher.launch(url)
        case .url(let url):
            if !NSWorkspace.shared.open(url) { core.showMessage("Couldn't open contact action", tone: .neutral) }
        case .maps(let url):
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Maps") else { return }
            Task {
                do {
                    _ = try await NSWorkspace.shared.open([url], withApplicationAt: app,
                        configuration: NSWorkspace.OpenConfiguration())
                } catch { core.showMessage("Couldn't open Maps", tone: .neutral) }
            }
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") else { return }
        NSWorkspace.shared.open(url)
    }
}
