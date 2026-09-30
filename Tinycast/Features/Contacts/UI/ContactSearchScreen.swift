import SwiftUI

struct ContactSearchScreen: PaletteScreen {
    let coordinator: ContactsCoordinator
    let vm: PaletteState
    let openActions: () -> Void

    var rows: [AppEntry] { coordinator.results(query: vm.query) }
    var primaryActionTitle: String { "Open in Contacts" }

    private func entry(at selection: Int) -> AppEntry? {
        let entries = rows
        return entries.indices.contains(selection) ? entries[selection] : nil
    }

    func activate(at selection: Int) {
        if let entry = entry(at: selection) { coordinator.open(entry) }
    }

    func secondary(at selection: Int) -> Bool {
        guard let entry = entry(at: selection) else { return false }
        coordinator.open(entry)
        return true
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        guard let entry = entry(at: selection) else { return false }
        return coordinator.perform(shortcut, entry: entry)
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        entry(at: selection).flatMap { coordinator.actions(for: $0) }
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(content(selection: selection, scroll: scroll))
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        let entries = rows
        if coordinator.store.access != .authorized {
            ContactsAccessView(coordinator: coordinator)
        } else if entries.isEmpty {
            EmptyResults(text: emptyMessage)
        } else {
            LauncherList(results: entries, selectedRowID: entry(at: selection)?.id,
                favoriteCount: 0, suggestionCount: 0, showSections: false, scroll: scroll,
                onActivate: { coordinator.open($0) },
                onActions: { entry in
                    if let index = entries.firstIndex(where: { $0.id == entry.id }) { vm.selection = index }
                    openActions()
                }, onDropped: {})
        }
    }

    private var emptyMessage: String {
        if coordinator.store.isLoading { return "Loading Contacts…" }
        if coordinator.store.failed { return "Couldn't Load Contacts — Reopen Search Contacts to Retry" }
        return vm.query.isEmpty ? "No Contacts Found" : "No contacts match “\(vm.query)”"
    }
}

