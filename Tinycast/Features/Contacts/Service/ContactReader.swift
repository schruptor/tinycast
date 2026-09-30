import Contacts
import Foundation

// Apple documents CNContactStore as thread-safe; the immutable owner bridges its Sendable gap.
nonisolated final class ContactReader: @unchecked Sendable {
    private let store = CNContactStore()
    static func access() -> ContactsAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    static func requestAccess() async {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
    }

    func load(options: ContactsOptions) throws -> [AppEntry] {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactIdentifierKey as CNKeyDescriptor, CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor, CNContactImageDataAvailableKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var entries: [AppEntry] = []
        try store.enumerateContacts(with: request) { contact, stop in
            if Task.isCancelled { stop.pointee = true; return }
            let value = Self.entry(contact)
            var app = AppEntry(
                id: value.entryID, name: value.displayName,
                url: URL(string: "tinycast://contacts")!, bundleID: nil, kind: .contact,
                subtitle: value.subtitle, symbolName: "person.crop.circle")
            app.contact = value
            app.search = EntryNaming.profile(for: value.naming(
                phones: options.phones, emails: options.emails, organizations: options.organizations))
            entries.append(app)
        }
        try Task.checkCancellation()
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func entry(_ contact: CNContact) -> ContactEntry {
        let phones = contact.phoneNumbers.map {
            ContactEntry.Value(label: label($0.label, fallback: "Phone"), value: $0.value.stringValue)
        }
        let emails = contact.emailAddresses.map {
            ContactEntry.Value(label: label($0.label, fallback: "Email"), value: $0.value as String)
        }
        let name = ContactEntry.displayName(
            formattedName: CNContactFormatter.string(from: contact, style: .fullName),
            organization: contact.organizationName, email: emails.first?.value, phone: phones.first?.value)
        return ContactEntry(
            id: contact.identifier, displayName: name, givenName: contact.givenName,
            middleName: contact.middleName, familyName: contact.familyName, nickname: contact.nickname,
            organization: contact.organizationName, jobTitle: contact.jobTitle, phones: phones, emails: emails,
            addresses: contact.postalAddresses.map {
                ContactEntry.Value(label: label($0.label, fallback: "Address"),
                    value: CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress))
            },
            websites: contact.urlAddresses.map {
                ContactEntry.Value(label: label($0.label, fallback: "Website"), value: $0.value as String)
            }, hasImage: contact.imageDataAvailable)
    }

    func thumbnail(id: String) -> Data? {
        guard Self.access() == .authorized, !Task.isCancelled else { return nil }
        let contact = try? store.unifiedContact(
            withIdentifier: id, keysToFetch: [CNContactThumbnailImageDataKey as CNKeyDescriptor])
        return contact?.thumbnailImageData
    }

    private static func label(_ raw: String?, fallback: String) -> String {
        raw.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? fallback
    }
}
