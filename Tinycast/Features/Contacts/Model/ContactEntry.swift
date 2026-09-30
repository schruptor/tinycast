import Foundation

struct ContactEntry: Identifiable, Hashable, Sendable {
    struct Value: Hashable, Sendable {
        let label: String
        let value: String
    }

    let id: String
    let displayName: String
    var givenName = ""
    var middleName = ""
    var familyName = ""
    var nickname = ""
    var organization = ""
    var jobTitle = ""
    var phones: [Value] = []
    var emails: [Value] = []
    var addresses: [Value] = []
    var websites: [Value] = []
    var hasImage = false

    var entryID: String { "contact:" + id }
    var subtitle: String? {
        [organization, emails.first?.value, phones.first?.value]
            .compactMap { $0 }.first { !$0.isEmpty }
    }
    var primaryValue: String { emails.first?.value ?? phones.first?.value ?? displayName }

    static func displayName(formattedName: String?, organization: String, email: String?, phone: String?) -> String {
        [formattedName, organization, email, phone].compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Unnamed Contact"
    }

    static func phoneDigits(_ value: String) -> String {
        String(value.compactMap { $0.wholeNumberValue }.map { Character(String($0)) })
    }

    static func searchQuery(_ query: String) -> String {
        let digits = phoneDigits(query)
        guard digits.count >= 3,
            query.allSatisfy({ $0.wholeNumberValue != nil || "+ -()/ .".contains($0) })
        else { return query }
        return digits
    }

    func naming(phones: Bool, emails: Bool, organizations: Bool) -> EntryNaming.Sources {
        var sources = EntryNaming.Sources(name: displayName)
        sources.alternateTitles = [nickname, givenName, middleName, familyName]
        sources.subtitle = organizations && !organization.isEmpty ? organization : nil
        if sources.subtitle == nil, emails { sources.subtitle = self.emails.first?.value }
        if sources.subtitle == nil, phones { sources.subtitle = self.phones.first?.value }
        sources.keywords = [jobTitle]
        if organizations { sources.keywords.append(organization) }
        if emails { sources.keywords += self.emails.map(\.value) }
        if phones { sources.keywords += self.phones.map { Self.phoneDigits($0.value) } }
        return sources
    }

    var details: String {
        ([displayName, organization, jobTitle].filter { !$0.isEmpty }
            + (phones + emails + addresses + websites).map { "\($0.label): \($0.value)" })
            .joined(separator: "\n")
    }
}
