import SwiftUI

struct ContactAvatar: View {
    let contact: ContactEntry
    @Environment(ContactsCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(\.metrics) private var metrics
    @State private var image: NSImage?

    private var showsImage: Bool { settings.contactsEnabled && settings.contactsShowPhotos && contact.hasImage }

    var body: some View {
        Group {
            if showsImage, let image {
                Image(nsImage: image).resizable().scaledToFill().clipShape(Circle())
            } else {
                SymbolImage(name: "person.crop.circle", size: metrics.size.resultRowIcon)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
        .task(id: "\(contact.id):\(showsImage):\(coordinator.store.revision)") {
            image = nil
            guard showsImage else { return }
            let loaded = await coordinator.store.thumbnail(id: contact.id)
            guard !Task.isCancelled else { return }
            image = loaded
        }
        .onDisappear { image = nil }
    }
}
