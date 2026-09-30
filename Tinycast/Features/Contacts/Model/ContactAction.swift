import Foundation

struct ContactAction: Sendable {
    enum Destination: Sendable {
        case contacts
        case copy(String)
        case url(URL)
        case maps(URL)
    }
    let title: String
    let symbol: String
    let destination: Destination
    var shortcut: String?

    static func actions(for contact: ContactEntry) -> [ContactAction] {
        var actions = [
            ContactAction(title: "Open in Contacts", symbol: "person.crop.circle", destination: .contacts, shortcut: "↵"),
            ContactAction(title: "Copy Name", symbol: "doc.on.doc", destination: .copy(contact.displayName), shortcut: "⌥⌘C"),
            ContactAction(title: "Copy Primary Value", symbol: "doc.on.doc",
                destination: .copy(contact.primaryValue), shortcut: "⇧⌘C")
        ]
        for email in contact.emails {
            actions.append(.init(title: "Copy \(email.label) Email", symbol: "doc.on.doc", destination: .copy(email.value)))
            if let url = link(scheme: "mailto", value: email.value) {
                actions.append(.init(title: "Send Email to \(email.value)",
                    symbol: "envelope", destination: .url(url)))
            }
        }
        for phone in contact.phones {
            actions.append(.init(title: "Copy \(phone.label) Phone Number",
                symbol: "doc.on.doc", destination: .copy(phone.value)))
            let digits = ContactEntry.phoneDigits(phone.value)
            guard !digits.isEmpty,
                phone.value.allSatisfy({ $0.wholeNumberValue != nil || "+ -()/ .".contains($0) })
            else { continue }
            let dial = (phone.value.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : "") + digits
            for (scheme, title, symbol) in [("tel", "Call", "phone"), ("facetime", "FaceTime", "video")] {
                if let url = link(scheme: scheme, value: dial) {
                    actions.append(.init(title: "\(title) \(phone.value)", symbol: symbol, destination: .url(url)))
                }
            }
        }
        for address in contact.addresses {
            actions.append(.init(title: "Copy \(address.label) Address", symbol: "doc.on.doc", destination: .copy(address.value)))
            var maps = URLComponents(string: "https://maps.apple.com/")!
            maps.queryItems = [URLQueryItem(name: "q", value: address.value)]
            if let url = maps.url {
                actions.append(.init(title: "Open \(address.label) Address in Maps", symbol: "map", destination: .maps(url)))
            }
        }
        for website in contact.websites {
            actions.append(.init(title: "Copy \(website.label) Website", symbol: "doc.on.doc", destination: .copy(website.value)))
            let value = website.value.contains("://") ? website.value : "https://" + website.value
            if let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                actions.append(.init(title: "Open \(website.label) Website", symbol: "globe", destination: .url(url)))
            }
        }
        actions.append(.init(title: "Copy All Contact Details", symbol: "doc.text", destination: .copy(contact.details)))
        return actions
    }

    private static func link(scheme: String, value: String) -> URL? {
        guard !value.isEmpty,
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        return URL(string: scheme + ":" + encoded)
    }
}
