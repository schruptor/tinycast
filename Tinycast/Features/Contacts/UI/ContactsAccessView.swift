import SwiftUI

struct ContactsAccessView: View {
    let coordinator: ContactsCoordinator
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(spacing: metrics.spacing.md) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(metrics.typography.rowTitle)
            Text("Contacts Access Required").font(metrics.typography.rowTitle)
            Text("Tinycast needs access to your contacts so you can search them.")
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(.secondary)
            if coordinator.store.access == .notDetermined {
                Button("Grant Access") { coordinator.grantAccess() }
            } else if coordinator.store.access == .denied {
                Button("Open System Settings") { coordinator.openSystemSettings() }
            } else {
                Text("Contacts access is restricted by this Mac's policy.")
                    .font(metrics.typography.rowTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
