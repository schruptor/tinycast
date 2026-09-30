import Foundation

@main
@MainActor
struct ContactsTest {
    static var passed = 0
    static var failed = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition { passed += 1 } else { failed += 1; print("FAIL: \(message)") }
    }

    static func main() {
        check(ContactEntry.displayName(formattedName: "Max Mustermann", organization: "Company",
            email: "max@example.com", phone: nil) == "Max Mustermann", "formatted Apple name wins")
        check(ContactEntry.displayName(formattedName: "", organization: "Company",
            email: nil, phone: nil) == "Company", "organization fallback")
        check(ContactEntry.displayName(formattedName: nil, organization: "", email: "max@example.com",
            phone: nil) == "max@example.com", "email fallback")
        check(ContactEntry.displayName(formattedName: "  ", organization: "", email: nil,
            phone: nil) == "Unnamed Contact", "empty fallback")
        check(ContactEntry.displayName(formattedName: nil, organization: "", email: nil,
            phone: "123") == "123", "phone fallback")

        let contact = ContactEntry(id: "one", displayName: "Max Mustermann", givenName: "Max",
            familyName: "Mustermann", nickname: "Manni", organization: "PLANETHOLDING GmbH", jobTitle: "Developer",
            phones: [.init(label: "Mobile", value: "+49 170 123456")],
            emails: [.init(label: "Work", value: "max@example.com"), .init(label: "Home", value: "max@home.de")],
            addresses: [.init(label: "Work", value: "Musterstraße 1\n26789 Leer")],
            websites: [.init(label: "Work", value: "https://example.com")])
        let profile = EntryNaming.profile(for: contact.naming(phones: true, emails: true, organizations: true))
        for query in ["max", "must", "manni", "planetholding", "max@", "example", "49170", "123456",
            "+49 170 123456", "49170123456", "49 170 123456", "+49 (170)/123-456"] {
            check(!rank([profile], query: query).isEmpty, "finds \(query)")
        }
        let namesOnly = EntryNaming.profile(for: contact.naming(phones: false, emails: false, organizations: false))
        for query in ["49170", "example", "planetholding"] {
            check(rank([namesOnly], query: query).isEmpty, "optional search field disabled: \(query)")
        }
        let international = ContactEntry(id: "two", displayName: "Müller Телеграм")
        let internationalProfile = EntryNaming.profile(for: international.naming(phones: true, emails: true, organizations: true))
        for query in ["muller", "telegram", "Телеграм"] {
            check(!rank([internationalProfile], query: query).isEmpty, "existing fold/transliteration: \(query)")
        }
        check(ContactEntry.phoneDigits("+49 (170)/123-456") == "49170123456", "phone punctuation removed")
        check(ContactEntry.searchQuery("Max 49") == "Max 49", "mixed name query preserved")
        check(contact.entryID == "contact:one", "namespaced identifier")
        check(contact.subtitle == "PLANETHOLDING GmbH", "organization context")
        check(contact.primaryValue == "max@example.com", "primary email")
        check(contact.details.contains("Mobile: +49 170 123456") && contact.details.contains("Home: max@home.de"),
            "all details and Apple labels kept")

        let actions = ContactAction.actions(for: contact)
        check(actions.contains { $0.title == "Open in Contacts" }, "default open action")
        check(actions.filter { $0.title.hasPrefix("Send Email") }.count == 2, "every email can send")
        check(actions.contains { $0.title.hasPrefix("Call") }, "phone call")
        check(actions.contains { $0.title.hasPrefix("FaceTime") }, "FaceTime")
        check(actions.contains { $0.title.contains("in Maps") }, "Maps")
        check(actions.contains { $0.title.hasPrefix("Open Work Website") }, "website")
        let extensionNumber = ContactEntry(id: "extension", displayName: "Desk",
            phones: [.init(label: "Work", value: "+49 123 ext. 99")])
        check(!ContactAction.actions(for: extensionNumber).contains { $0.title.hasPrefix("Call") },
            "ambiguous dialing extensions are not joined into a different number")
        let emptyActions = ContactAction.actions(for: ContactEntry(id: "empty", displayName: "Unnamed Contact"))
        check(emptyActions.count == 4, "no phantom actions for empty fields")
        let malicious = ContactEntry(id: "unsafe", displayName: "Website",
            websites: [.init(label: "Other", value: "file:///tmp/private")])
        check(!ContactAction.actions(for: malicious).contains { $0.title.hasPrefix("Open Other Website") },
            "websites only open HTTP or HTTPS")

        let ordinary = EntryNaming.profile(for: EntryNaming.Sources(name: "+49 170 123456"))
        let mixed = LauncherOrder.ranked([ordinary, profile], query: .init("+49 170 123456"),
            sensitivity: .default, limit: 200,
            queryForItem: { $0 == profile ? .init(ContactEntry.searchQuery("+49 170 123456")) : nil },
            profile: { $0 }, signals: { LauncherOrder.Signals(usage: .unused, priority: 1, title: $0.title.string) })
        check(mixed.count == 2, "phone normalization preserves ordinary launcher entries")

        let path = URL(filePath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let ranking = LauncherRankingStore(fileURL: path, now: { Date(timeIntervalSince1970: 1000) })
        ranking.visit(itemKey: contact.entryID, query: nil)
        let usage = ranking.snapshot().usage(for: contact.entryID)
        check(usage.searchTerms.isEmpty, "contact queries never persist")
        let order = LauncherOrder.byUsage(["contact:other", contact.entryID]) {
            LauncherOrder.Signals(usage: ranking.snapshot().usage(for: $0), priority: 1, title: "Max Mustermann")
        }
        check(order.first == contact.entryID, "existing learned frecency ranks chosen Max first")
        let many = Array(repeating: profile, count: 10_000)
        let start = ContinuousClock.now
        let results = rank(many, query: "max")
        print("10,000-contact matching: \(start.duration(to: .now))")
        check(results.count == 200, "large index uses existing result limit")
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func rank(_ profiles: [SearchProfile], query: String) -> [SearchProfile] {
        LauncherOrder.ranked(profiles, query: .init(ContactEntry.searchQuery(query)), sensitivity: .default,
            limit: 200, profile: { $0 }, signals: {
                LauncherOrder.Signals(usage: .unused, priority: 1, title: $0.title.string)
            })
    }
}
