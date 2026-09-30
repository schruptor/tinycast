import SwiftUI

struct ContactsSettingsView: View {
    @Environment(ContactsCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            FeatureSwitchSection(anchor: .contactsContacts, enableTitle: "Enable Contacts",
                enableSubtitle: "Search your Apple contacts. Nothing leaves this Mac.",
                isEnabled: Binding(get: { settings.contactsEnabled }, set: { coordinator.setEnabled($0) }),
                showsInLauncher: $settings.contactsShowInLauncher, showsIcon: true)
            if settings.contactsEnabled, coordinator.store.access != .authorized {
                Section {
                    if coordinator.store.access == .notDetermined {
                        Button("Grant Access") { coordinator.grantAccess() }
                    } else if coordinator.store.access == .denied {
                        Button("Open System Settings") { coordinator.openSystemSettings() }
                    } else {
                        Text("Contacts access is restricted by this Mac's policy.")
                    }
                }
            }
            Section {
                Toggle(isOn: $settings.contactsSearchPhones) {
                    SettingsRowTitle(.contactsSearch, "Search phone numbers")
                }
                Toggle(isOn: $settings.contactsSearchEmails) {
                    SettingsRowTitle(.contactsSearch, "Search email addresses")
                }
                Toggle(isOn: $settings.contactsSearchOrganizations) {
                    SettingsRowTitle(.contactsSearch, "Search organizations")
                }
            } header: { SettingsSectionHeader(.contactsSearch) }
            .settingsEnabled(settings.contactsEnabled)
            Section {
                Toggle(isOn: $settings.contactsShowPhotos) {
                    SettingsRowTitle(.contactsAppearance, "Show contact photos")
                }
            } header: { SettingsSectionHeader(.contactsAppearance) }
            .settingsEnabled(settings.contactsEnabled)
            FeatureCommandsSection(owner: .contacts, anchor: .contactsCommands)
                .settingsEnabled(settings.contactsEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.contacts)
        .task { coordinator.prepare() }
    }
}
