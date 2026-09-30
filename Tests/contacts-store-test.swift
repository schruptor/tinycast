import AppKit
import Contacts

// The service only needs the launcher's value shape; the app build checks its full wiring.
struct AppEntry: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case contact }
    let id: String
    let name: String
    let url: URL
    let bundleID: String?
    let kind: Kind
    var subtitle: String?
    var symbolName: String?
    var contact: ContactEntry?
    var search = SearchProfile.unnamed
}

final class ContactFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AppEntry] = []
    private var status = ContactsAccess.authorized
    private var active = 0
    private(set) var maximumActive = 0
    private var reads = 0
    private var asks = 0

    func set(_ contacts: [AppEntry], access: ContactsAccess = .authorized) {
        lock.withLock { values = contacts; status = access }
    }

    func access() -> ContactsAccess { lock.withLock { status } }
    func askCount() -> Int { lock.withLock { asks } }
    func grant() { lock.withLock { asks += 1; status = .authorized } }
    func readCount() -> Int { lock.withLock { reads } }
    func load(_: ContactsOptions) -> [AppEntry] {
        lock.withLock { active += 1; reads += 1; maximumActive = max(maximumActive, active) }
        Thread.sleep(forTimeInterval: 0.03)
        return lock.withLock { active -= 1; return values }
    }
}

@main
@MainActor
struct ContactsStoreTest {
    static var passed = 0
    static var failed = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition { passed += 1 } else { failed += 1; print("FAIL: \(message)") }
    }

    static func settle(_ store: ContactsStore) async {
        try? await Task.sleep(for: .milliseconds(10))
        for _ in 0..<300 {
            if !store.isLoading { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        check(false, "refresh completes")
    }

    static func main() async {
        let raw = CNMutableContact()
        raw.givenName = "Max"
        raw.familyName = "Mustermann"
        raw.nickname = "Manni"
        raw.organizationName = "PLANETHOLDING GmbH"
        raw.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+49 170 123456"))]
        raw.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: "max@example.com" as NSString)]
        let contact = ContactReader.entry(raw)
        check(contact.displayName == CNContactFormatter.string(from: raw, style: .fullName), "Apple name formatter used")
        check(contact.phones.first?.label == CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: CNLabelPhoneNumberMobile),
            "localized Apple label")
        let organization = CNMutableContact()
        organization.organizationName = "Example GmbH"
        check(ContactReader.entry(organization).displayName == "Example GmbH", "organization-only native contact")
        check(ContactReader.entry(CNMutableContact()).displayName == "Unnamed Contact", "empty native contact")
        let email = CNMutableContact()
        email.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "only@example.com" as NSString)]
        check(ContactReader.entry(email).displayName == "only@example.com", "email-only native contact")
        let row = AppEntry(id: contact.entryID, name: contact.displayName, url: URL(string: "tinycast://contacts")!,
            bundleID: nil, kind: .contact, contact: contact)
        let fixture = ContactFixture()
        fixture.set([row])
        let store = ContactsStore(readAccess: fixture.access, load: fixture.load, askAccess: {})
        check(store.entries.isEmpty && fixture.readCount() == 0, "disabled does no work")
        store.start(options: .init())
        await settle(store)
        check(store.entries.count == 1, "native values published")
        check(store.launcherEntries(showsInLauncher: true).count == 1, "root entries enabled")
        check(store.launcherEntries(showsInLauncher: false).isEmpty && store.entries.count == 1,
            "root hidden leaves Search Contacts data intact")

        let before = fixture.readCount()
        fixture.set([])
        for _ in 0..<20 { NotificationCenter.default.post(name: .CNContactStoreDidChange, object: nil) }
        try? await Task.sleep(for: .milliseconds(400))
        await settle(store)
        check(store.entries.isEmpty, "deleted contact removed after store change")
        check(fixture.readCount() == before + 1, "change burst debounced")
        check(fixture.maximumActive == 1, "refreshes never overlap")

        fixture.set([row])
        for _ in 0..<10 { store.refresh() }
        await settle(store)
        check(fixture.maximumActive == 1, "reentrant refresh serialized")
        store.stop()
        check(store.entries.isEmpty && store.launcherEntries(showsInLauncher: true).isEmpty,
            "disable withdraws all contact data")
        let stoppedReads = fixture.readCount()
        NotificationCenter.default.post(name: .CNContactStoreDidChange, object: nil)
        try? await Task.sleep(for: .milliseconds(350))
        check(fixture.readCount() == stoppedReads, "disabled observer does no background work")

        fixture.set([row], access: .denied)
        store.start(options: .init())
        await settle(store)
        check(store.access == .denied && store.entries.isEmpty && fixture.readCount() == stoppedReads,
            "denied permission fetches nothing and cannot crash")
        store.stop()
        fixture.set([row], access: .restricted)
        store.start(options: .init())
        check(store.access == .restricted && store.entries.isEmpty, "restricted access has no data")
        store.stop()
        fixture.set([row])
        store.start(options: .init())
        try? await Task.sleep(for: .milliseconds(5))
        store.stop()
        try? await Task.sleep(for: .milliseconds(100))
        check(store.entries.isEmpty, "in-flight load cannot resurrect disabled contacts")
        store.start(options: .init())
        await settle(store)
        check(store.entries.count == 1, "reenabling reloads")
        store.stop()
        fixture.set([row], access: .notDetermined)
        let lazy = ContactsStore(readAccess: fixture.access, load: fixture.load, askAccess: { fixture.grant() })
        lazy.start(options: .init())
        check(lazy.access == .notDetermined && fixture.askCount() == 0, "starting never requests access")
        await lazy.requestAccess()
        check(lazy.access == .authorized && fixture.askCount() == 1, "explicit gesture requests access")
        await lazy.requestAccess()
        check(fixture.askCount() == 1, "authorization is not requested twice")
        lazy.stop()

        let failure = ContactsStore(readAccess: { .authorized }, load: { _ in throw CocoaError(.fileReadUnknown) },
            askAccess: {})
        failure.start(options: .init())
        await settle(failure)
        check(failure.failed && failure.entries.isEmpty, "fetch failure surfaces without contact contents")
        failure.stop()
        check(!failure.failed, "disable resets fetch failure")

        fixture.set([row])
        store.start(options: .init())
        try? await Task.sleep(for: .milliseconds(5))
        store.stop()
        fixture.set([])
        store.start(options: .init())
        try? await Task.sleep(for: .milliseconds(100))
        await settle(store)
        check(store.entries.isEmpty && fixture.maximumActive == 1,
            "disable and immediate re-enable reject the old generation without overlapping fetches")
        store.stop()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
