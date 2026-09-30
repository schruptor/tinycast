import Foundation

struct ClipboardRepresentation: Codable, Hashable, Sendable {
    let type: String
    let data: Data

    static let maximumBytes = 256 * 1024
    static let maximumEntryBytes = 512 * 1024
    static let maximumStoredBytes = 32 * 1024 * 1024
    static let allowedTypes: Set<String> = [
        "public.utf8-plain-text", "public.utf16-plain-text", "public.rtf",
        "com.apple.flat-rtfd", "public.html", "public.url", "public.png", "public.tiff",
        "com.apple.cocoa.pasteboard.color"
    ]

    static func bounded(_ representations: [Self]) -> [Self] {
        var bytes = 0
        var types: Set<String> = []
        return representations.filter {
            guard allowedTypes.contains($0.type), !$0.data.isEmpty,
                $0.data.count <= maximumBytes,
                bytes + $0.data.count <= maximumEntryBytes,
                types.insert($0.type).inserted
            else { return false }
            bytes += $0.data.count
            return true
        }
    }
}

enum ClipboardPasteMode: String, CaseIterable, Sendable {
    case original, plainText, richText, html, url, image, color

    var title: String {
        switch self {
        case .original: "Original"
        case .plainText: "Plain Text"
        case .richText: "Rich Text"
        case .html: "HTML"
        case .url: "URL"
        case .image: "Image"
        case .color: "Color"
        }
    }

    func selects(_ type: String, available: [String]) -> Bool {
        switch self {
        case .original: true
        case .plainText: type == "public.utf8-plain-text"
        case .richText:
            type == (available.contains("com.apple.flat-rtfd") ? "com.apple.flat-rtfd" : "public.rtf")
        case .html: type == "public.html"
        case .url: type == "public.url"
        case .image: type == (available.contains("public.png") ? "public.png" : "public.tiff")
        case .color: type == "com.apple.cocoa.pasteboard.color"
        }
    }

    static func preferred(for item: ClipboardItem, plainText: Bool) -> Self {
        plainText && item.kind == .text ? .plainText : .original
    }

    static func appendsNewline(to item: ClipboardItem, enabled: Bool) -> Bool {
        enabled && item.kind == .text
    }

    static func available(for item: ClipboardItem) -> [Self] {
        var modes: [Self] = [.original]
        if item.plainText != nil { modes.append(.plainText) }
        let types = item.representationTypes
        if types.contains("public.rtf") || types.contains("com.apple.flat-rtfd") {
            modes.append(.richText)
        }
        if types.contains("public.html") { modes.append(.html) }
        if types.contains("public.url") { modes.append(.url) }
        if item.kind == .text, types.contains("public.png") || types.contains("public.tiff") {
            modes.append(.image)
        }
        if types.contains("com.apple.cocoa.pasteboard.color") { modes.append(.color) }
        return modes
    }
}

enum ClipboardSequenceTimeout: Int, CaseIterable, Identifiable, Sendable {
    case fiveSeconds = 5, tenSeconds = 10, thirtySeconds = 30
    case minute = 60, twoMinutes = 120, fiveMinutes = 300

    var id: Int { rawValue }
    var title: String {
        rawValue < 60 ? "\(rawValue) Seconds" : "\(rawValue / 60) \(rawValue == 60 ? "Minute" : "Minutes")"
    }
}
